import CSQLite
import Foundation
import Testing

@testable import ClipEchoCore

@Suite struct TrayPreviewTests {
  private func fixture() throws -> (URL, SQLiteStore) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ClipEchoTrayPreview-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return (
      directory,
      try SQLiteStore(
        url: directory.appendingPathComponent("clipecho.db"),
        locator: StorageLocator(root: directory))
    )
  }

  private func insert(_ text: String, into store: SQLiteStore, formatted: Bool = false) throws
    -> String
  {
    var values = [ClipboardRepresentation(type: EventClassifier.textType, data: Data(text.utf8))]
    if formatted {
      values.append(
        ClipboardRepresentation(type: "public.rtf", data: Data("{\\rtf1 synthetic}".utf8)))
    }
    let event = ClipboardEvent(items: [ClipboardItem(dataList: values)])
    let prepared = try #require(EventClassifier.prepare(event: event, compactMode: false))
    #expect(try store.insert(prepared: prepared))
    return prepared.contentHash
  }

  private func replaceDisplay(_ display: Data, hash: String, store: SQLiteStore) throws {
    var connection: OpaquePointer?
    var statement: OpaquePointer?
    guard sqlite3_open_v2(store.url.path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK
    else { throw StorageError.inaccessible }
    defer {
      sqlite3_finalize(statement)
      sqlite3_close(connection)
    }
    guard
      sqlite3_prepare_v2(
        connection,
        "UPDATE clipboard_events SET compact_display = ?1, event_data = X'00' WHERE content_hash = ?2",
        -1, &statement, nil) == SQLITE_OK
    else { throw StorageError.inaccessible }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    _ = display.withUnsafeBytes {
      sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), transient)
    }
    _ = hash.withCString { sqlite3_bind_text(statement, 2, $0, -1, transient) }
    guard sqlite3_step(statement) == SQLITE_DONE else { throw StorageError.inaccessible }
  }

  @Test func clippedUnicodeKeepsCompleteScalarsAndReportsOriginalLength() throws {
    let (directory, store) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let hash = try insert("A中🙂Z", into: store)
    let expected = ["A", "A", "A", "A中", "A中", "A中", "A中", "A中🙂", "A中🙂Z"]
    for (index, text) in expected.enumerated() {
      let preview = try #require(try store.trayPreviewDetails(contentHash: hash, limit: index + 1))
      #expect(preview.dataType == "text")
      #expect(preview.display == Data(text.utf8))
      #expect(preview.truncated == (index < expected.count - 1))
      #expect(try store.trayPreview(contentHash: hash, limit: index + 1) == preview.display)
    }
    #expect(try store.trayPreviewDetails(contentHash: hash, limit: 0)?.display == Data("A".utf8))
  }

  @Test func hardByteLimitAndExactBoundaryHaveDistinctMetadata() throws {
    let (directory, store) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let exact = String(repeating: "x", count: 65_536)
    let exactHash = try insert(exact, into: store)
    let overHash = try insert(exact + "中", into: store)
    let exactPreview = try #require(
      try store.trayPreviewDetails(contentHash: exactHash, limit: Int.max))
    let overPreview = try #require(
      try store.trayPreviewDetails(contentHash: overHash, limit: Int.max))
    #expect(exactPreview.display.count == 65_536)
    #expect(!exactPreview.truncated)
    #expect(overPreview.display == Data(exact.utf8))
    #expect(overPreview.truncated)
    let cutHash = try insert(String(repeating: "a", count: 65_535) + "🙂", into: store)
    let cut = try #require(try store.trayPreviewDetails(contentHash: cutHash))
    #expect(cut.display.count == 65_535)
    #expect(cut.truncated)
    #expect(EventCodec.strictUTF8(cut.display) != nil)
  }

  @Test func malformedBytesArePreservedInsteadOfRepairingCorruptContent() throws {
    let (directory, store) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let hash = try insert("synthetic malformed display", into: store)
    let malformed: [[UInt8]] = [
      [0x61, 0xff, 0xe2], [0x61, 0xe0, 0x80], [0x61, 0xed, 0xa0], [0x61, 0xf4, 0x90], [0x61, 0x80],
      [0x61, 0xc0],
    ]
    for bytes in malformed {
      let display = Data(bytes)
      try replaceDisplay(display, hash: hash, store: store)
      let preview = try #require(try store.trayPreviewDetails(contentHash: hash))
      #expect(preview.display == display)
      #expect(!preview.truncated)
      #expect(EventCodec.strictUTF8(preview.display) == nil)
    }
    try replaceDisplay(Data([0x61, 0xf0, 0x9f]), hash: hash, store: store)
    let incomplete = try #require(try store.trayPreviewDetails(contentHash: hash))
    #expect(incomplete.display == Data("a".utf8))
    #expect(!incomplete.truncated)
  }

  @Test func formattedPreviewUsesLinePreservingPlainTextWithoutDecodingPayload() throws {
    let (directory, store) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = "  first line\nsecond line\n"
    let hash = try insert(source, into: store, formatted: true)
    try replaceDisplay(Data(source.utf8), hash: hash, store: store)
    let full = try #require(try store.trayPreviewDetails(contentHash: hash))
    #expect(full.dataType == "rtf")
    #expect(full.display == Data(source.utf8))
    #expect(!full.truncated)
    try store.setSetting(key: "compact_mode", value: "true")
    let compact = try #require(try store.trayPreviewDetails(contentHash: hash))
    #expect(compact.dataType == "text")
    #expect(compact.display == Data(source.utf8))
    #expect(!compact.truncated)
  }

  @Test func absentAndImageRowsDoNotProduceTextPreviews() throws {
    let (directory, store) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(try store.trayPreviewDetails(contentHash: String(repeating: "a", count: 64)) == nil)
    let event = ClipboardEvent(items: [
      ClipboardItem(dataList: [
        ClipboardRepresentation(type: "public.png", data: Data([0x89, 0x50, 0x4e, 0x47]))
      ])
    ])
    let prepared = try #require(EventClassifier.prepare(event: event, compactMode: false))
    #expect(try store.insert(prepared: prepared))
    let image = try #require(try store.trayPreviewDetails(contentHash: prepared.contentHash))
    #expect(image.dataType == "png")
    #expect(try store.trayPreview(contentHash: prepared.contentHash) == nil)
    try store.setSetting(key: "compact_mode", value: "true")
    #expect(try store.trayPreviewDetails(contentHash: prepared.contentHash) == nil)
  }
}
