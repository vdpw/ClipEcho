import CSQLite
import Darwin
import Foundation
import Testing
@testable import ClipEchoCore

@Suite struct HistoryMirrorTests {
    private func fixture() throws -> (URL, SQLiteStore) {
        // SQLite SQLITE_OPEN_NOFOLLOW rejects macOS's /var -> /private/var alias.
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("clipecho-mirror-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return (root, try SQLiteStore(url: root.appendingPathComponent("clipecho.db")))
    }
    private func text(_ value: String) -> ClipboardEvent {
        ClipboardEvent(items: [ClipboardItem(dataList: [ClipboardRepresentation(type: EventClassifier.textType, data: Data(value.utf8))])])
    }
    private func records(_ output: URL) throws -> [[String: Any]] {
        try Data(contentsOf: output).split(separator: 10).map { line in
            try #require(try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
        }
    }
    private func execute(_ url: URL, sql: String) throws {
        var connection: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE, nil)
        guard opened == SQLITE_OK else { throw StorageError.database(opened) }
        defer { sqlite3_close(connection) }
        let result = sqlite3_exec(connection, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw StorageError.database(result) }
    }

    @Test func coalescedSnapshotUsesLegacyByteFieldsAndPrivateAtomicFile() async throws {
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try #require(EventClassifier.prepare(event: text("你好XYZ"), compactMode: false))
        try store.insert(prepared: prepared)
        let output = root.appendingPathComponent("history.jsonl")
        let mirror = try HistoryMirror(configuration: HistoryMirrorConfiguration(outputURL: output, maxDataBytes: 4, debounce: .seconds(5)), databaseURL: store.url)
        for _ in 0..<20 { try await mirror.scheduleRefresh() }
        try await mirror.flush()
        let status = await mirror.status()
        #expect(status.requestedGeneration == 20)
        #expect(status.writtenGeneration == 20)
        let values = try records(output)
        #expect(values.count == 1)
        let display = try #require(values[0]["display"] as? [String: Any])
        #expect(display["byte_len"] as? Int == 9)
        #expect(display["encoding"] as? String == "utf8")
        #expect(display["value"] as? String == "你")
        #expect(display["truncated"] as? Bool == true)
        #expect(values[0]["is_remote_clipboard"] == nil)
        #expect(values[0]["source_bundle_id"] == nil)
        let permissions = try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? NSNumber
        #expect((permissions?.intValue ?? 0) & 0o777 == 0o600)
        try await mirror.shutdown()
    }

    @Test func corruptRowPreservesPriorCompleteSnapshot() async throws {
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try #require(EventClassifier.prepare(event: text("original"), compactMode: false))
        try store.insert(prepared: prepared)
        let output = root.appendingPathComponent("history.jsonl")
        let mirror = try HistoryMirror(configuration: HistoryMirrorConfiguration(outputURL: output), databaseURL: store.url)
        try await mirror.scheduleRefresh(); try await mirror.flush()
        let original = try Data(contentsOf: output)
        try execute(store.url, sql: "UPDATE clipboard_events SET event_data = X'000102' WHERE content_hash = '\(prepared.contentHash)'")
        try await mirror.scheduleRefresh()
        await #expect(throws: HistoryMirror.Failure.eventDecode) { try await mirror.flush() }
        #expect(try Data(contentsOf: output) == original)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!files.contains { $0.hasPrefix(".clipecho-history-") })
        try? await mirror.shutdown()
    }

    @Test func compactSnapshotProjectsIdentityAndProtocolMarkers() async throws {
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let event = ClipboardEvent(items: [ClipboardItem(dataList: [
            ClipboardRepresentation(type: EventClassifier.textType, data: Data("effective text".utf8)),
            ClipboardRepresentation(type: "public.html", data: Data("<strong>effective text</strong>".utf8)),
            ClipboardRepresentation(type: PasteboardProtocol.sourceType, data: Data("com.synthetic".utf8)),
            ClipboardRepresentation(type: PasteboardProtocol.remoteType, data: Data()),
        ])])
        let prepared = try #require(EventClassifier.prepare(event: event, compactMode: false))
        try store.insert(prepared: prepared); try store.setSetting(key: "compact_mode", value: "true")
        let output = root.appendingPathComponent("history.jsonl")
        let mirror = try HistoryMirror(configuration: HistoryMirrorConfiguration(outputURL: output), databaseURL: store.url)
        try await mirror.scheduleRefresh(); try await mirror.flush()
        let row = try #require(try records(output).first)
        #expect(row["content_hash"] as? String == prepared.compactContentHash)
        #expect(row["data_type"] as? String == "text")
        #expect(row["source_bundle_id"] as? String == "com.synthetic")
        #expect(row["is_remote_clipboard"] as? Bool == true)
        let eventData = try #require(row["event_data"] as? [String: Any])
        let items = try #require(eventData["items"] as? [[String: Any]])
        let flavors = try #require(items[0]["data_list"] as? [[String: Any]])
        #expect(flavors.compactMap { $0["type"] as? String } == [EventClassifier.textType, PasteboardProtocol.sourceType, PasteboardProtocol.remoteType])
        try await mirror.shutdown()
    }

    @Test func mirrorRejectsDatabaseCollisionAndSymlinkDestination() throws {
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: HistoryMirror.Failure.databaseCollision) {
            try HistoryMirror(configuration: HistoryMirrorConfiguration(outputURL: store.url), databaseURL: store.url)
        }
        for suffix in ["-WAL", "-SHM", "-JOURNAL"] {
            #expect(throws: HistoryMirror.Failure.databaseCollision) {
                try HistoryMirror(configuration: HistoryMirrorConfiguration(outputURL: URL(fileURLWithPath: store.url.path + suffix)), databaseURL: store.url)
            }
        }
        let victim = root.appendingPathComponent("victim.txt")
        try Data("unchanged".utf8).write(to: victim)
        let output = root.appendingPathComponent("history.jsonl")
        try FileManager.default.createSymbolicLink(at: output, withDestinationURL: victim)
        #expect(throws: HistoryMirror.Failure.unsafePath) {
            try HistoryMirror(configuration: HistoryMirrorConfiguration(outputURL: output), databaseURL: store.url)
        }
        #expect(try Data(contentsOf: victim) == Data("unchanged".utf8))
    }
}
