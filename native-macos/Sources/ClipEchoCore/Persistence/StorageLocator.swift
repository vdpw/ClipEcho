import Foundation
import Darwin

/// Reads the same bootstrap and move-recovery records as the original app.
/// Resolution is read-only: a pending recovery remains authoritative until a move is completed.
public struct StorageLocator: Sendable {
    public let root: URL
    public init(root: URL? = nil) {
        if let root { self.root = root.standardizedFileURL }
        else if let override = ProcessInfo.processInfo.environment["COPY_STACK_QA_DATA_DIR"] {
            self.root = URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        } else {
            self.root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clipecho", isDirectory: true)
        }
    }

    public func databaseURL() throws -> URL {
        guard root.path.hasPrefix("/") else { throw StorageError.unsafePath }
        if FileManager.default.fileExists(atPath: root.path) { try PrivateStorage.validateDirectory(root) }
        if let recovery: MoveRecovery = try readJSON("storage-move.json") {
            let source = try absoluteURL(recovery.source), destination = try absoluteURL(recovery.destination)
            let selected: URL
            if try PrivateStorage.identityIfPresent(source) != nil {
                guard try PrivateStorage.identityIfPresent(source) == recovery.sourceIdentity else { throw StorageError.invalidConfiguration }
                selected = source
            } else {
                guard try PrivateStorage.identityIfPresent(destination) == recovery.destinationIdentity else { throw StorageError.invalidConfiguration }
                selected = destination
            }
            try PrivateStorage.validateDirectory(selected.deletingLastPathComponent())
            return try PrivateStorage.canonicalDirectory(selected.deletingLastPathComponent()).appendingPathComponent(selected.lastPathComponent)
        }
        if let config: LocationConfig = try readJSON("storage.json") {
            let directory = try absoluteURL(config.directory)
            try PrivateStorage.validateDirectory(directory)
            let database = directory.appendingPathComponent("clipecho.db")
            guard try PrivateStorage.identityIfPresent(database) != nil else { throw StorageError.invalidConfiguration }
            return try PrivateStorage.canonicalDirectory(directory).appendingPathComponent("clipecho.db")
        }
        try PrivateStorage.validateAncestors(root, allowMissing: true)
        return try PrivateStorage.canonicalDirectory(root, allowMissing: true).appendingPathComponent("clipecho.db")
    }

    private func absoluteURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw StorageError.invalidConfiguration }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
    private func readJSON<T: Decodable>(_ name: String) throws -> T? {
        let file = root.appendingPathComponent(name)
        guard let identity = try PrivateStorage.identityIfPresent(file) else { return nil }
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw StorageError.inaccessible }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, UInt64(bitPattern: Int64(opened.st_dev)) == identity.device, UInt64(opened.st_ino) == identity.inode else { throw StorageError.unsafePath }
        let bytes = try handle.read(upToCount: 16_385) ?? Data()
        guard bytes.count <= 16_384 else { throw StorageError.invalidConfiguration }
        do {
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw StorageError.invalidConfiguration }
            let required: Set<String> = name == "storage.json" ? ["directory"] : ["source", "destination", "source_identity", "destination_identity"]
            guard Set(object.keys) == required else { throw StorageError.invalidConfiguration }
            guard try PrivateStorage.identityIfPresent(file) == identity else { throw StorageError.unsafePath }
            return try JSONDecoder().decode(T.self, from: bytes)
        }
        catch { throw StorageError.invalidConfiguration }
    }
    func save(directory: URL) throws {
        try writeJSON(LocationConfig(directory: directory.path), name: "storage.json")
    }
    func saveRecovery(source: URL, destination: URL) throws {
        guard let sourceIdentity = try PrivateStorage.identityIfPresent(source),
              let destinationIdentity = try PrivateStorage.identityIfPresent(destination) else { throw StorageError.moveFailed }
        try writeJSON(MoveRecovery(source: source.path, destination: destination.path,
                                  sourceIdentity: sourceIdentity, destinationIdentity: destinationIdentity), name: "storage-move.json")
    }
    func finishRecovery() { try? FileManager.default.removeItem(at: root.appendingPathComponent("storage-move.json")) }
    private func writeJSON<T: Encodable>(_ value: T, name: String) throws {
        try PrivateStorage.ensureDirectory(root, privateDirectory: true)
        let target = root.appendingPathComponent(name)
        let targetIdentity = try PrivateStorage.identityIfPresent(target)
        let temp = root.appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StorageError.inaccessible }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temp) }
        do {
            try handle.write(contentsOf: JSONEncoder().encode(value)); try handle.synchronize()
            guard try PrivateStorage.identityIfPresent(target) == targetIdentity else { throw StorageError.unsafePath }
            guard rename(temp.path, target.path) == 0 else { throw StorageError.inaccessible }
            let directoryFD = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            if directoryFD >= 0 { _ = fsync(directoryFD); close(directoryFD) }
        } catch let error as StorageError { throw error }
        catch { throw StorageError.inaccessible }
    }
}

private struct LocationConfig: Codable { let directory: String }
private struct MoveRecovery: Codable {
    let source: String; let destination: String
    let sourceIdentity: PrivateStorage.Identity; let destinationIdentity: PrivateStorage.Identity
    enum CodingKeys: String, CodingKey {
        case source, destination
        case sourceIdentity = "source_identity", destinationIdentity = "destination_identity"
    }
}

enum PrivateStorage {
    struct Identity: Codable, Equatable, Sendable { let device: UInt64; let inode: UInt64 }
    static func identityIfPresent(_ url: URL, tighten: Bool = false) throws -> Identity? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }; throw StorageError.inaccessible
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else { throw StorageError.unsafePath }
        if tighten && info.st_mode & 0o077 != 0 {
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw StorageError.inaccessible }
            defer { close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else { throw StorageError.unsafePath }
            guard fchmod(descriptor, info.st_mode & 0o600) == 0 else { throw StorageError.inaccessible }
        }
        guard info.st_mode & 0o400 != 0 else { throw StorageError.inaccessible }
        return Identity(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino))
    }
    static func validateDirectory(_ url: URL) throws {
        try validateAncestors(url)
        var info = stat()
        guard url.path.hasPrefix("/"), lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
              info.st_mode & 0o022 == 0, info.st_mode & 0o700 == 0o700 else { throw StorageError.unsafePath }
    }
    static func ensureDirectory(_ url: URL, privateDirectory: Bool = false) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw StorageError.inaccessible }
            try validateAncestors(url, allowMissing: true)
            do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { throw StorageError.inaccessible }
        }
        try validateAncestors(url)
        if privateDirectory {
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { throw StorageError.unsafePath }
            let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw StorageError.inaccessible }
            defer { close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else { throw StorageError.unsafePath }
            guard fchmod(descriptor, info.st_mode & 0o700) == 0 else { throw StorageError.inaccessible }
        }
        try validateDirectory(url)
    }
    static func createFile(_ url: URL) throws {
        let fd = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw errno == EEXIST ? StorageError.destinationExists : StorageError.inaccessible }
        close(fd)
    }
    static func canonicalDirectory(_ url: URL, allowMissing: Bool = false) throws -> URL {
        try validateAncestors(url, allowMissing: allowMissing)
        var current = url.path, suffix: [String] = []
        while true {
            if let resolved = realpath(current, nil) {
                defer { free(resolved) }
                var result = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
                for component in suffix.reversed() { result.appendPathComponent(component, isDirectory: true) }
                return result
            }
            guard allowMissing, errno == ENOENT, current != "/" else { throw StorageError.inaccessible }
            let path = current as NSString
            suffix.append(path.lastPathComponent); current = path.deletingLastPathComponent
        }
    }
    static func validateAncestors(_ url: URL, allowMissing: Bool = false) throws {
        var current = "/"
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            let parent = current
            current = current == "/" ? "/\(component)" : "\(current)/\(component)"
            var info = stat()
            if lstat(current, &info) != 0 {
                if errno == ENOENT && allowMissing {
                    var parentInfo = stat()
                    guard stat(parent, &parentInfo) == 0, parentInfo.st_uid == getuid(),
                          parentInfo.st_mode & 0o022 == 0, parentInfo.st_mode & 0o700 == 0o700 else { throw StorageError.unsafePath }
                    return
                }
                throw StorageError.inaccessible
            }
            if info.st_mode & S_IFMT == S_IFLNK {
                var parentInfo = stat(), targetInfo = stat()
                // macOS's root-owned /var and /tmp links are trusted, as in the Rust implementation.
                guard info.st_uid == 0, lstat(parent, &parentInfo) == 0, parentInfo.st_uid == 0,
                      parentInfo.st_mode & S_IFMT == S_IFDIR, parentInfo.st_mode & 0o022 == 0,
                      stat(current, &targetInfo) == 0, targetInfo.st_uid == 0,
                      targetInfo.st_mode & S_IFMT == S_IFDIR else { throw StorageError.unsafePath }
            } else if info.st_mode & S_IFMT != S_IFDIR { throw StorageError.unsafePath }
        }
    }
}
