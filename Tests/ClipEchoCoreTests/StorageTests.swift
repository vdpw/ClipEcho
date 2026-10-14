import Testing
import Foundation
import CSQLite
@testable import ClipEchoCore

@Suite struct StorageTests {
    private func fixture() throws -> (URL, StorageLocator, SQLiteStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClipEchoStorage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let locator = StorageLocator(root: directory)
        return (directory, locator, try SQLiteStore(url: directory.appendingPathComponent("clipecho.db"), locator: locator))
    }
    private func event(_ text: String, formatted: Bool = false) -> ClipboardEvent {
        var flavors = [ClipboardRepresentation(type: "public.utf8-plain-text", data: Data(text.utf8))]
        if formatted { flavors.append(ClipboardRepresentation(type: "public.html", data: Data("<b>\(text)</b>".utf8))) }
        return ClipboardEvent(items: [ClipboardItem(dataList: flavors)])
    }
    private func insert(_ text: String, store: SQLiteStore, formatted: Bool = false) throws -> String {
        let compact = try store.settings().compactMode
        let prepared = try #require(EventClassifier.prepare(event: event(text, formatted: formatted), compactMode: compact))
        #expect(try store.insert(prepared: prepared))
        return prepared.contentHash
    }
    private func sql(_ url: URL, _ command: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw StorageError.inaccessible }
        defer { sqlite3_close(db) }
        let rc = sqlite3_exec(db, command, nil, nil, nil)
        guard rc == SQLITE_OK else { throw StorageError.database(rc) }
    }
    private func scalar(_ url: URL, _ query: String) throws -> Int64 {
        var db: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw StorageError.inaccessible }
        defer { sqlite3_finalize(statement); sqlite3_close(db) }
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { throw StorageError.inaccessible }
        return sqlite3_column_int64(statement, 0)
    }

    @Test func testCurrentSchemaSharesSettingsAndRestorablePayload() throws {
        let (directory, locator, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let hash = try insert("shared existing database", store: store)
        try store.setSetting(key: "theme", value: "dark")
        try store.setSetting(key: "language", value: "zh-CN")
        let existing = try SQLiteStore(url: store.url, readOnly: true, locator: locator)
        #expect(try existing.settings().theme == "dark")
        #expect(try existing.settings().language == "zh-CN")
        #expect(try existing.page().items.map(\.contentHash) == [hash])
        let stored = try #require(try existing.event(contentHash: hash))
        #expect(try EventCodec.decode(stored.eventData) == event("shared existing database"))
        #expect(try scalar(store.url, "PRAGMA user_version") == 4)
        #expect(try scalar(store.url, "SELECT COUNT(*) FROM clipboard_event_search") == 1)
    }

    @Test func testDuplicateCapturePreservesTimestampAndPin() throws {
        let (directory, _, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let first = try insert("first", store: store)
        let timestamp = try #require(try store.event(contentHash: first)).item.timestamp
        _ = try insert("second", store: store)
        #expect(try store.setPinned(contentHash: first, pinned: true))
        _ = try insert("first", store: store)
        let repeated = try #require(try store.event(contentHash: first))
        #expect(repeated.item.timestamp == timestamp)
        #expect(repeated.item.isPinned)
        #expect(try store.stats().totalItems == 2)
        try store.moveToTop(contentHash: first)
        #expect(try #require(try store.event(contentHash: first)).item.timestamp > timestamp)
    }

    @Test func testSourceMarkersPreserveExplicitEmptyAndUTF8NULWithoutChangingIdentity() throws {
        let (directory, _, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        for source in ["", "app\0中文"] {
            var value = event("same source-independent content")
            value.items[0].dataList.append(ClipboardRepresentation(type: PasteboardProtocol.sourceType, data: Data(source.utf8)))
            value.items[0].dataList.append(ClipboardRepresentation(type: PasteboardProtocol.remoteType, data: Data()))
            let prepared = try #require(EventClassifier.prepare(event: value, compactMode: false))
            try store.insert(prepared: prepared)
            let stored = try #require(try store.event(contentHash: prepared.contentHash))
            #expect(stored.sourceBundleID == source)
            #expect(stored.isRemoteClipboard)
            #expect(try store.stats().totalItems == 1)
        }
    }

    @Test func testPinProtectionCountAndByteRetentionAndClear() throws {
        let (directory, _, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let pinned = try insert("pinned", store: store)
        try store.setPinned(contentHash: pinned, pinned: true)
        try store.setSetting(key: "max_items", value: "1")
        _ = try insert("immediately evicted", store: store)
        #expect(try store.page().items.map(\.contentHash) == [pinned])
        try store.setSetting(key: "max_history_bytes", value: "0")
        #expect(try store.stats().totalItems == 1)
        try store.clear()
        #expect(try store.stats().totalItems == 1)
        #expect(!(try store.delete(contentHash: pinned, allowPinned: false)))
        try store.setPinned(contentHash: pinned, pinned: false)
        #expect(try store.stats().totalItems == 0)
        #expect(try scalar(store.url, "SELECT COUNT(*) FROM clipboard_event_search") == 0)
    }

    @Test func testCompactProjectionCanonicalizationAggregatesPinsAndDeletesGroup() throws {
        let (directory, _, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let rich = try insert("same effective text", store: store, formatted: true)
        let plain = try insert("same effective text", store: store)
        try store.setPinned(contentHash: rich, pinned: true)
        try store.setSetting(key: "compact_mode", value: "true")
        let page = try store.page()
        #expect(page.items.count == 1)
        #expect(page.items[0].contentHash == plain)
        #expect(page.items[0].isPinned)
        let originalTimestamp = page.items[0].timestamp
        _ = try insert("same effective text", store: store)
        #expect(try store.stats().totalItems == 1)
        let canonical = try #require(try store.event(contentHash: plain))
        #expect(canonical.item.isPinned)
        #expect(canonical.item.timestamp == originalTimestamp)
        #expect(try EventCodec.decode(canonical.eventData) == event("same effective text"))
        #expect(try scalar(store.url, "SELECT COUNT(*) FROM clipboard_event_search") == 1)
        try store.delete(contentHash: plain)
        #expect(try store.stats().totalItems == 0)
    }

    @Test func testCursorIncludesPinTimestampAndHashAcrossEqualTimestampBoundary() throws {
        let (directory, _, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let hashes = try ["one", "two", "three", "four"].map { try insert($0, store: store) }
        try store.setPinned(contentHash: hashes[0], pinned: true)
        try store.setPinned(contentHash: hashes[1], pinned: true)
        try sql(store.url, "UPDATE clipboard_events SET timestamp = 100")
        var seen: [HistoryItem] = [], cursor: HistoryCursor?
        repeat {
            let page = try store.page(cursor: cursor, limit: 1)
            seen += page.items; cursor = page.nextCursor
        } while cursor != nil
        #expect(seen.count == 4)
        #expect(Set(seen.map(\.contentHash)) == Set(hashes))
        #expect(seen.map(\.isPinned) == [true, true, false, false])
        #expect(seen.prefix(2).map(\.contentHash) == Array(hashes.prefix(2)).sorted())
        let encoded = HistoryCursor(isPinned: true, timestamp: 100, contentHash: hashes[0]).encoded
        #expect(try HistoryCursor(encoded: encoded).encoded == encoded)
        #expect(throws: (any Error).self) { try HistoryCursor(encoded: "v2:0:100:short") }
    }

    @Test func testSearchHandlesCJKQuotesAndMatchesOutsideSummaryWithoutDecodingEvent() throws {
        let (directory, _, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        _ = try insert("中文 quote \"needle\" " + String(repeating: "a", count: 600) + " deep-match", store: store)
        #expect(try store.page(query: "中").totalCount == 1)
        #expect(try store.page(query: "中文").totalCount == 1)
        #expect(try store.page(query: "\"needle\"").totalCount == 1)
        #expect(try store.page(query: "deep-match").totalCount == 1)
        #expect(try #require(try store.page(query: "deep-match").items.first?.searchPreview).contains("deep-match"))
        #expect(try store.page().items[0].display.count <= 512)
        #expect(throws: (any Error).self) { try store.page(query: "\0") }
        #expect(throws: (any Error).self) { try store.page(query: String(repeating: "x", count: 257)) }
    }

    @Test func testInvalidSettingAndReadOnlyMutationAreRejectedWithoutChanges() throws {
        let (directory, locator, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let prior = try store.settings()
        for value in ["0", "1048577", "269484032", "invalid"] {
            #expect(throws: (any Error).self) { try store.setSetting(key: "max_event_bytes", value: value) }
        }
        #expect(try store.settings() == prior)
        let inspector = try SQLiteStore(url: store.url, readOnly: true, locator: locator)
        #expect(throws: StorageError.readOnly) { try inspector.setSetting(key: "theme", value: "light") }
        #expect(throws: StorageError.readOnly) { try inspector.clear() }
    }

    @Test func testFutureSchemaAndUnknownLegacyRemainUnchanged() throws {
        let (directory, locator, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        _ = try insert("preserve this history", store: store)
        try sql(store.url, "PRAGMA user_version = 99")
        #expect(throws: StorageError.unsupportedSchema(99)) { try SQLiteStore(url: store.url, locator: locator) }
        #expect(try scalar(store.url, "PRAGMA user_version") == 99)
        #expect(try scalar(store.url, "SELECT COUNT(*) FROM clipboard_events") == 1)
        let legacy = directory.appendingPathComponent("legacy.db")
        try sql(legacy, "CREATE TABLE clipboard_events (id INTEGER PRIMARY KEY, event_data BLOB NOT NULL); PRAGMA user_version = 0")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacy.path)
        #expect(throws: StorageError.unsupportedSchema(0)) { try SQLiteStore(url: legacy, locator: locator) }
        #expect(try scalar(legacy, "PRAGMA user_version") == 0)
    }

    @Test func testV3PinMigrationPreservesPayloadAndTimestamps() throws {
        let (directory, locator, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let hash = try insert("v3 history", store: store)
        let original = try #require(try store.event(contentHash: hash))
        try sql(store.url, "DROP INDEX idx_clipboard_events_pinned; ALTER TABLE clipboard_events DROP COLUMN is_pinned; PRAGMA user_version = 3")
        let upgraded = try SQLiteStore(url: store.url, locator: locator)
        let migrated = try #require(try upgraded.event(contentHash: hash))
        #expect(migrated.eventData == original.eventData)
        #expect(migrated.item.timestamp == original.item.timestamp)
        #expect(!(migrated.item.isPinned))
        #expect(try scalar(store.url, "PRAGMA user_version") == 4)
    }

    @Test func testMissingSearchRowsRebuildFromPersistedDisplays() throws {
        let (directory, locator, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        _ = try insert("rebuild 中文 searchable display", store: store)
        try sql(store.url, "DELETE FROM clipboard_event_search")
        let reopened = try SQLiteStore(url: store.url, locator: locator)
        #expect(try reopened.page(query: "searchable").totalCount == 1)
        #expect(try reopened.page(query: "中").totalCount == 1)
        #expect(try scalar(store.url, "SELECT COUNT(*) FROM clipboard_event_search") == 1)
    }

    @Test func testRelocationPreservesHistoryAndBootstrapAndRejectsOverwrite() throws {
        let (directory, locator, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let hash = try insert("relocated history", store: store)
        try store.setPinned(contentHash: hash, pinned: true)
        let destination = directory.appendingPathComponent("new-store", isDirectory: true)
        let old = store.url
        try store.moveStorage(to: destination)
        #expect(try store.url == PrivateStorage.canonicalDirectory(destination).appendingPathComponent("clipecho.db"))
        #expect(!(FileManager.default.fileExists(atPath: old.path)))
        for suffix in ["-wal", "-shm", "-journal"] { #expect(!(FileManager.default.fileExists(atPath: old.path + suffix))) }
        #expect(try locator.databaseURL() == store.url)
        #expect(try #require(try store.event(contentHash: hash)).item.isPinned)
        let reopened = try SQLiteStore(url: locator.databaseURL(), locator: locator)
        #expect(try reopened.page().items.map(\.contentHash) == [hash])
        let occupied = directory.appendingPathComponent("occupied", isDirectory: true)
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: occupied.appendingPathComponent("clipecho.db-wal").path, contents: Data(), attributes: [.posixPermissions: 0o600])
        #expect(throws: StorageError.destinationExists) { try store.moveStorage(to: occupied) }
        #expect(try store.page().items.count == 1)
    }

    @Test func testRecoveryRecordKeepsSourceAuthoritativeUntilRemoval() throws {
        let (directory, locator, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target", isDirectory: true)
        try PrivateStorage.ensureDirectory(target)
        let other = try SQLiteStore(url: target.appendingPathComponent("clipecho.db"), locator: locator)
        try locator.saveRecovery(source: store.url, destination: other.url)
        try locator.save(directory: target)
        #expect(try locator.databaseURL() == store.url)
        try FileManager.default.removeItem(at: store.url)
        #expect(try locator.databaseURL() == other.url)
    }

    @Test func testBlockedConfigurationRollbackKeepsRecoverableSourceAndSnapshot() throws {
        let (directory, locator, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let hash = try insert("rollback must preserve source", store: store)
        let source = store.url, destination = directory.appendingPathComponent("failed-move", isDirectory: true)
        let sentinel = directory.appendingPathComponent("sentinel")
        try Data("unchanged".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("storage.json"), withDestinationURL: sentinel)
        #expect(throws: (any Error).self) { try store.moveStorage(to: destination) }
        #expect(store.url == source)
        #expect(try locator.databaseURL() == source)
        #expect(try store.page().items.map(\.contentHash) == [hash])
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("clipecho.db").path))
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "unchanged")
    }

    @Test func testMirrorSnapshotStaysConsistentAcrossConcurrentMutationAndUsesCompactIdentity() throws {
        let (directory, locator, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        _ = try insert("snapshot first", store: store)
        _ = try insert("snapshot second", store: store)
        let reader = try SQLiteStore(url: store.url, readOnly: true, locator: locator)
        var rows: [HistorySnapshotRow] = []
        try reader.visitSnapshotRows { row in
            rows.append(row)
            if rows.count == 1 { _ = try insert("written during snapshot", store: store) }
        }
        #expect(rows.count == 2)
        #expect(try store.stats().totalItems == 3)
        try store.clear()
        let rich = try insert("compact snapshot", store: store, formatted: true)
        try store.setSetting(key: "compact_mode", value: "true")
        rows.removeAll()
        try reader.visitSnapshotRows { rows.append($0) }
        #expect(rows.count == 1)
        #expect(rows[0].contentHash != rich)
        #expect(rows[0].contentHash == EventClassifier.hash(Data("compact snapshot".utf8)))
        #expect(rows[0].dataType == "text")
        #expect(try EventCodec.decode(rows[0].eventData) == event("compact snapshot"))
    }

    @Test func testSystemAliasesResolveWhileUserSymlinkPathsAndHardLinkedFilesAreRejected() throws {
        let (directory, locator, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try store.url.deletingLastPathComponent() == PrivateStorage.canonicalDirectory(directory))
        let target = directory.appendingPathComponent("actual", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let alias = directory.appendingPathComponent("user-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        #expect(throws: StorageError.unsafePath) { try SQLiteStore(url: alias.appendingPathComponent("clipecho.db"), locator: locator) }
        #expect(!(FileManager.default.fileExists(atPath: target.appendingPathComponent("clipecho.db").path)))
        let symbolic = directory.appendingPathComponent("symbolic.db")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: store.url)
        #expect(throws: StorageError.unsafePath) { try SQLiteStore(url: symbolic, readOnly: true, locator: locator) }
        let hardLink = directory.appendingPathComponent("hard-link.db")
        try FileManager.default.linkItem(at: store.url, to: hardLink)
        #expect(throws: StorageError.unsafePath) { try SQLiteStore(url: hardLink, readOnly: true, locator: locator) }
    }
}
