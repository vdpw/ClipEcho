import Darwin
import Foundation

public struct HistoryMirrorConfiguration: Sendable {
    public let outputURL: URL
    public let maxDataBytes: Int
    public let debounce: Duration
    public init(outputURL: URL, maxDataBytes: Int = 4096, debounce: Duration = .milliseconds(200)) {
        self.outputURL = outputURL.standardizedFileURL
        self.maxDataBytes = maxDataBytes
        self.debounce = debounce
    }
}

/// Coalesced JSONL snapshots read through a dedicated connection. Refresh
/// signals contain no clipboard bodies, and a failure keeps the prior file.
public actor HistoryMirror {
    public enum Failure: Error, LocalizedError, Equatable, Sendable {
        case invalidConfiguration, unsafePath, databaseCollision, snapshotRead, eventDecode, write, stopped
        public var errorDescription: String? { "The private clipboard history snapshot could not be updated." }
    }
    public struct Status: Sendable {
        public let requestedGeneration: UInt64
        public let settledGeneration: UInt64
        public let writtenGeneration: UInt64
        public let lastFailure: Failure?
        public let stopped: Bool
    }

    private let configuration: HistoryMirrorConfiguration
    private var databaseURL: URL
    private var storage: SQLiteStore?
    private var pendingTask: Task<Void, Never>?
    private var requested: UInt64 = 0
    private var settled: UInt64 = 0
    private var written: UInt64 = 0
    private var lastFailure: Failure?
    private var paused = false
    private var stopped = false

    public init(configuration: HistoryMirrorConfiguration, databaseURL: URL) throws {
        guard configuration.outputURL.isFileURL, configuration.outputURL.path.hasPrefix("/"),
              !configuration.outputURL.path.contains("\0"), configuration.maxDataBytes >= 0 else { throw Failure.invalidConfiguration }
        self.configuration = configuration
        self.databaseURL = databaseURL.standardizedFileURL
        try Self.validateDestination(configuration.outputURL, databaseURL: self.databaseURL)
        do {
            try PrivateStorage.ensureDirectory(configuration.outputURL.deletingLastPathComponent())
            _ = try PrivateStorage.identityIfPresent(configuration.outputURL, tighten: true)
        } catch { throw Failure.unsafePath }
    }

    @discardableResult public func scheduleRefresh() throws -> UInt64 {
        guard !stopped, requested < UInt64.max else { throw Failure.stopped }
        requested += 1
        pendingTask?.cancel()
        guard !paused else { return requested }
        let delay = configuration.debounce
        pendingTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.settlePending()
        }
        return requested
    }

    public func status() -> Status {
        Status(requestedGeneration: requested, settledGeneration: settled,
               writtenGeneration: written, lastFailure: lastFailure, stopped: stopped)
    }

    /// Runs a pending generation immediately; serialization and I/O remain on
    /// this actor. Call before process termination when a final snapshot matters.
    public func flush() throws {
        guard !stopped else { throw Failure.stopped }
        pendingTask?.cancel(); pendingTask = nil
        if requested > settled && !paused { settlePending() }
        if let lastFailure { throw lastFailure }
    }

    public func shutdown() throws {
        defer { stopped = true; pendingTask?.cancel(); pendingTask = nil; storage = nil }
        try flush()
    }

    /// Await this before moving the live SQLite database. Actor serialization
    /// guarantees existing readers have finished before the connection closes.
    public func pauseForRelocation(to destination: URL) throws {
        guard !stopped else { throw Failure.stopped }
        try Self.validateDestination(configuration.outputURL, databaseURL: destination)
        paused = true; pendingTask?.cancel(); pendingTask = nil; storage = nil
    }

    /// Resume with the actual authoritative path after success or rollback.
    public func resume(databaseURL: URL) throws {
        guard !stopped else { throw Failure.stopped }
        try Self.validateDestination(configuration.outputURL, databaseURL: databaseURL)
        storage = nil; self.databaseURL = databaseURL.standardizedFileURL; paused = false
        try scheduleRefresh()
    }

    private func settlePending() {
        guard !stopped, !paused, requested > settled else { return }
        let generation = requested
        pendingTask = nil
        do {
            try writeSnapshot()
            written = generation; lastFailure = nil
        } catch let failure as Failure { lastFailure = failure }
        catch { lastFailure = .write }
        settled = generation
    }

    private func writeSnapshot() throws {
        do {
            if storage == nil { storage = try SQLiteStore(url: databaseURL, readOnly: true) }
        } catch { throw Failure.snapshotRead }
        guard let storage else { throw Failure.snapshotRead }
        let destination = configuration.outputURL
        let directory = destination.deletingLastPathComponent()
        let originalIdentity: PrivateStorage.Identity?
        do { try PrivateStorage.validateDirectory(directory); originalIdentity = try PrivateStorage.identityIfPresent(destination, tighten: true) }
        catch { throw Failure.unsafePath }
        let temporary = directory.appendingPathComponent(".clipecho-history-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.write }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        do {
            try storage.visitSnapshotRows { row in
                let event: ClipboardEvent
                do { event = try EventCodec.decode(row.eventData) } catch { throw Failure.eventDecode }
                // A disallowed externally edited row never leaks into a mirror.
                guard PasteboardProtocol.assess(event).shouldRecord else { return }
                let record = MirrorRecord(row: row, event: event, maxDataBytes: configuration.maxDataBytes)
                let encoded = try encoder.encode(record)
                try handle.write(contentsOf: encoded)
                try handle.write(contentsOf: Data([10]))
            }
            try handle.synchronize()
            guard try PrivateStorage.identityIfPresent(destination) == originalIdentity else { throw Failure.unsafePath }
            guard rename(temporary.path, destination.path) == 0 else { throw Failure.write }
            let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directoryFD >= 0 else { throw Failure.write }
            defer { close(directoryFD) }
            guard fsync(directoryFD) == 0 else { throw Failure.write }
        } catch let failure as Failure { throw failure }
        catch let error as StorageError {
            switch error { case .unsafePath: throw Failure.unsafePath; default: throw Failure.snapshotRead }
        } catch { throw Failure.write }
    }

    private static func validateDestination(_ output: URL, databaseURL: URL) throws {
        // Resolve only the parent with POSIX realpath, then append the literal
        // filename. Foundation may rewrite /private/var to /var differently
        // depending on whether the final file exists, hiding sidecar aliases.
        let source: String
        let destination: String
        do {
            source = try canonicalFilePath(databaseURL).lowercased()
            destination = try canonicalFilePath(output).lowercased()
        } catch { throw Failure.unsafePath }
        guard !["", "-wal", "-shm", "-journal"].contains(where: { destination == source + $0 }) else { throw Failure.databaseCollision }
        // Lexical aliases and existing hard links to SQLite files are both rejected.
        if let outputIdentity = try? PrivateStorage.identityIfPresent(output) {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                if let sourceIdentity = try? PrivateStorage.identityIfPresent(URL(fileURLWithPath: databaseURL.path + suffix)), outputIdentity == sourceIdentity { throw Failure.databaseCollision }
            }
        }
    }

    private static func canonicalFilePath(_ url: URL) throws -> String {
        let directory = try PrivateStorage.canonicalDirectory(url.deletingLastPathComponent(), allowMissing: true)
        return directory.path + "/" + url.lastPathComponent
    }
}

private struct MirrorRecord: Encodable {
    let contentHash: String
    let dataType: String
    let timestamp: Int64
    let display: MirrorBytes
    let eventData: MirrorEvent
    let sourceBundleID: String?
    let isRemoteClipboard: Bool
    enum CodingKeys: String, CodingKey {
        case contentHash = "content_hash", dataType = "data_type", timestamp, display
        case eventData = "event_data", sourceBundleID = "source_bundle_id", isRemoteClipboard = "is_remote_clipboard"
    }
    init(row: HistorySnapshotRow, event: ClipboardEvent, maxDataBytes: Int) {
        contentHash = row.contentHash; dataType = row.dataType; timestamp = row.timestamp
        display = MirrorBytes(row.display, maxDataBytes: maxDataBytes)
        eventData = MirrorEvent(items: event.items.map { item in
            MirrorItem(dataList: item.dataList.map { MirrorData(type: $0.type, data: MirrorBytes($0.data, maxDataBytes: maxDataBytes)) })
        })
        sourceBundleID = row.sourceBundleID; isRemoteClipboard = row.isRemoteClipboard
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(contentHash, forKey: .contentHash); try values.encode(dataType, forKey: .dataType)
        try values.encode(timestamp, forKey: .timestamp); try values.encode(display, forKey: .display)
        try values.encode(eventData, forKey: .eventData); try values.encodeIfPresent(sourceBundleID, forKey: .sourceBundleID)
        if isRemoteClipboard { try values.encode(true, forKey: .isRemoteClipboard) }
    }
}
private struct MirrorEvent: Encodable { let items: [MirrorItem] }
private struct MirrorItem: Encodable {
    let dataList: [MirrorData]
    enum CodingKeys: String, CodingKey { case dataList = "data_list" }
}
private struct MirrorData: Encodable { let type: String; let data: MirrorBytes }
private struct MirrorBytes: Encodable {
    let byteLength: Int
    let truncated: Bool
    let encoding: String
    let value: String
    enum CodingKeys: String, CodingKey { case byteLength = "byte_len", truncated, encoding, value }
    init(_ data: Data, maxDataBytes: Int) {
        byteLength = data.count; truncated = data.count > maxDataBytes
        var end = min(maxDataBytes, data.count)
        if let text = EventCodec.strictUTF8(data) {
            while end > 0 && end < data.count && data[end] & 0xc0 == 0x80 { end -= 1 }
            encoding = "utf8"
            value = end == data.count ? text : String(decoding: data.prefix(end), as: UTF8.self)
        } else {
            encoding = "hex"; value = data.prefix(end).map { String(format: "%02x", $0) }.joined()
        }
    }
}
