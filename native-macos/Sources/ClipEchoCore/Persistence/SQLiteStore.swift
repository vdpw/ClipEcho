import CSQLite
import Foundation

/// Synchronous SQLite connection. The application confines it to its HistoryService actor.
/// History pages select persisted summaries; restore materializes exactly one bounded event.
public final class SQLiteStore {
  public private(set) var url: URL
  public let readOnly: Bool
  private var db: OpaquePointer?
  private let locator: StorageLocator
  private static let defaults: [String: String] = [
    "max_items": "100", "max_history_bytes": "268435456", "max_event_bytes": "33554432",
    "show_in_menu_bar": "true", "menu_bar_item_limit": "0", "move_restored_item_to_top": "false",
    "compact_mode": "false", "language": "system", "theme": "system",
  ]
  private static let eventColumns = [
    "content_hash", "event_data", "data_type", "display", "summary_display",
    "summary_truncated", "compact_content_hash", "compact_display", "source_bundle_id",
    "is_remote_clipboard",
    "byte_count", "timestamp", "metadata_version", "is_pinned",
  ]
  private static let compactFilter = """
    e.compact_content_hash IS NOT NULL AND e.compact_display IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM clipboard_events n WHERE n.compact_content_hash = e.compact_content_hash
        AND (n.timestamp > e.timestamp OR (n.timestamp = e.timestamp AND n.content_hash < e.content_hash)))
    """

  public init(url: URL, readOnly: Bool = false, locator: StorageLocator? = nil) throws {
    guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else {
      throw StorageError.unsafePath
    }
    self.url = url.standardizedFileURL
    self.readOnly = readOnly
    self.locator = locator ?? StorageLocator()
    let directory = self.url.deletingLastPathComponent()
    if readOnly {
      try PrivateStorage.validateDirectory(directory)
    } else {
      try PrivateStorage.ensureDirectory(
        directory, privateDirectory: directory == self.locator.root)
    }
    let originalIdentity = try PrivateStorage.identityIfPresent(self.url)
    // SQLite's NOFOLLOW flag also rejects Apple's /var and /tmp aliases. Validate every
    // original component first, then open the canonical parent with the original filename.
    self.url = try PrivateStorage.canonicalDirectory(directory).appendingPathComponent(
      self.url.lastPathComponent)
    var identity = try PrivateStorage.identityIfPresent(self.url)
    guard identity == originalIdentity else { throw StorageError.unsafePath }
    if identity == nil {
      guard !readOnly else { throw StorageError.inaccessible }
      try PrivateStorage.createFile(self.url)
      identity = try PrivateStorage.identityIfPresent(self.url)
    }
    for suffix in ["-wal", "-shm", "-journal"] {
      _ = try PrivateStorage.identityIfPresent(URL(fileURLWithPath: self.url.path + suffix))
    }
    var connection: OpaquePointer?
    let flags =
      (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_FULLMUTEX
      | SQLITE_OPEN_NOFOLLOW
    let result = sqlite3_open_v2(self.url.path, &connection, flags, nil)
    guard result == SQLITE_OK else {
      let extended = connection.map { sqlite3_extended_errcode($0) } ?? result
      let systemErrno = connection.map { sqlite3_system_errno($0) } ?? 0
      if let connection { sqlite3_close(connection) }
      throw StorageError.databaseOpen(extended, systemErrno)
    }
    db = connection
    do {
      guard try PrivateStorage.identityIfPresent(self.url) == identity else {
        throw StorageError.unsafePath
      }
      sqlite3_busy_timeout(db, 3_000)
      try initialize()
      if !readOnly {
        _ = try PrivateStorage.identityIfPresent(self.url, tighten: true)
        try run("PRAGMA journal_mode = WAL")
        try protectSidecars()
      }
    } catch {
      sqlite3_close(db)
      db = nil
      throw error
    }
  }

  deinit { if let db { sqlite3_close(db) } }

  public func settings() throws -> AppSettings {
    let values = try rows("SELECT key, value FROM settings") { [text($0, 0): text($0, 1)] }
      .reduce(into: [String: String]()) { $0.merge($1) { _, new in new } }
    func integer(_ key: String) throws -> Int64 {
      guard let value = Int64(values[key] ?? Self.defaults[key] ?? ""), value >= 0 else {
        throw StorageError.invalidSetting
      }
      return value
    }
    func boolean(_ key: String) -> Bool {
      switch values[key] {
      case "true", "1": return true
      case "false", "0": return false
      default: return Self.defaults[key] == "true"
      }
    }
    var result = AppSettings()
    let maxItems = try integer("max_items")
    let menuLimit = try integer("menu_bar_item_limit")
    guard maxItems <= Int64(Int.max), menuLimit <= Int64(Int.max) else {
      throw StorageError.invalidSetting
    }
    result.maxItems = Int(maxItems)
    result.menuBarItemLimit = Int(menuLimit)
    result.maxHistoryBytes = try integer("max_history_bytes")
    result.maxEventBytes = try integer("max_event_bytes")
    guard Self.validEventLimit(result.maxEventBytes) else { throw StorageError.invalidSetting }
    result.showInMenuBar = boolean("show_in_menu_bar")
    result.moveRestoredItemToTop = boolean("move_restored_item_to_top")
    result.compactMode = boolean("compact_mode")
    if let language = values["language"], ["system", "en", "zh-CN", "zh-TW"].contains(language) {
      result.language = language
    }
    if let theme = values["theme"], ["system", "light", "dark"].contains(theme) {
      result.theme = theme
    }
    return result
  }

  public func stats() throws -> HistoryStats {
    let totals = try rows("SELECT COUNT(*), COALESCE(SUM(byte_count), 0) FROM clipboard_events") {
      (sqlite3_column_int64($0, 0), sqlite3_column_int64($0, 1))
    }[0]
    let compact = try scalar("SELECT COUNT(*) FROM clipboard_events e WHERE \(Self.compactFilter)")
    return HistoryStats(
      totalItems: totals.0, totalBytes: max(0, totals.1), compactVisibleItems: compact)
  }

  public func page(cursor: HistoryCursor? = nil, limit: Int = 50, query: String = "") throws
    -> HistoryPage
  {
    let limit = min(100, max(1, limit))
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count <= 256, !query.contains("\0") else { throw StorageError.invalidQuery }
    if let cursor, !HistoryCursor.validHash(cursor.contentHash) { throw StorageError.invalidCursor }
    return try transaction(write: false) {
      let compact = try settings().compactMode
      let pin = pinExpression(compact: compact)
      let type = compact ? "'text'" : "e.data_type"
      let display = "substr(e.summary_display, 1, 512)"
      let truncated = "(e.summary_truncated OR length(e.summary_display) > 512)"
      var from = "clipboard_events e"
      var filter = compact ? Self.compactFilter : "1 = 1"
      var preview = "NULL"
      var args: [Value] = []
      if !query.isEmpty {
        from += " JOIN clipboard_event_search s ON s.content_hash = e.content_hash"
        let column = compact ? "compact_search_text" : "search_text"
        // A bounded excerpt shows a match outside the persisted 512-byte summary.
        preview =
          "substr(s.\(column), max(instr(lower(s.\(column)), lower(\(sqlLiteral(query)))) - 60, 1), 180)"
        if query.count >= 3 {
          filter += " AND clipboard_event_search MATCH ?"
          args.append(
            .string("\(column):\"\(query.replacingOccurrences(of: "\"", with: "\"\""))\""))
        } else {
          filter += " AND instr(lower(s.\(column)), lower(?)) > 0"
          args.append(.string(query))
        }
      }
      let totalCount = try scalar("SELECT COUNT(*) FROM \(from) WHERE \(filter)", args)
      var pageFilter = filter
      var pageArgs = args
      if let cursor {
        pageFilter +=
          " AND (\(pin) < ? OR (\(pin) = ? AND (e.timestamp < ? OR (e.timestamp = ? AND e.content_hash > ?))))"
        pageArgs += [
          .int(cursor.isPinned ? 1 : 0), .int(cursor.isPinned ? 1 : 0), .int(cursor.timestamp),
          .int(cursor.timestamp), .string(cursor.contentHash),
        ]
      }
      pageArgs.append(.int(Int64(limit + 1)))
      var items = try rows(
        """
        SELECT e.content_hash, \(type), \(display), \(truncated), e.timestamp,
               e.source_bundle_id, e.is_remote_clipboard, e.byte_count, \(pin), \(preview)
        FROM \(from) WHERE \(pageFilter)
        ORDER BY \(pin) DESC, e.timestamp DESC, e.content_hash ASC LIMIT ?
        """, pageArgs, map: summary)
      let hasMore = items.count > limit
      if hasMore { items.removeLast() }
      let next =
        hasMore
        ? items.last.map {
          HistoryCursor(isPinned: $0.isPinned, timestamp: $0.timestamp, contentHash: $0.contentHash)
        } : nil
      return HistoryPage(
        items: items, nextCursor: next, hasMore: hasMore, totalCount: totalCount,
        totalBytes: try scalar("SELECT COALESCE(SUM(byte_count), 0) FROM clipboard_events"))
    }
  }

  public func trayItems(limit: Int = 0) throws -> [HistoryItem] {
    let compact = try settings().compactMode
    let pin = pinExpression(compact: compact)
    return try rows(
      """
      SELECT e.content_hash, \(compact ? "'text'" : "e.data_type"),
             substr(e.summary_display, 1, 512), (e.summary_truncated OR length(e.summary_display) > 512), e.timestamp,
             e.source_bundle_id, e.is_remote_clipboard, e.byte_count, \(pin)
      FROM clipboard_events e WHERE \(compact ? Self.compactFilter : "1 = 1")
      ORDER BY \(pin) DESC, e.timestamp DESC, e.content_hash ASC LIMIT ?
      """, [.int(Int64(limit == 0 ? 1_000 : min(1_000, max(1, limit))))], map: summary)
  }

  public func trayPreview(contentHash: String, limit: Int = 65_536) throws -> Data? {
    guard let preview = try trayPreviewDetails(contentHash: contentHash, limit: limit),
      ["text", "rtf", "html"].contains(preview.dataType)
    else { return nil }
    return preview.display
  }

  /// Reads only persisted display bytes and original length. A clipped UTF-8
  /// scalar is removed at the boundary; malformed bytes elsewhere stay invalid.
  public func trayPreviewDetails(contentHash: String, limit: Int = 65_536) throws -> TrayPreview? {
    let compact = try settings().compactMode
    let maximum = min(65_536, max(1, limit))
    let display =
      compact
      ? "compact_display"
      : "CASE WHEN data_type IN ('text', 'rtf', 'html') THEN COALESCE(compact_display, display) ELSE summary_display END"
    return try rows(
      """
      SELECT \(compact ? "'text'" : "data_type"), substr(\(display), 1, ?), length(\(display)) > ?
      FROM clipboard_events WHERE content_hash = ?\(compact ? " AND compact_content_hash IS NOT NULL" : "")
      """, [.int(Int64(maximum)), .int(Int64(maximum)), .string(contentHash)]
    ) { statement in
      TrayPreview(
        dataType: text(statement, 0), display: Self.trimIncompleteUTF8Tail(blob(statement, 1)),
        truncated: sqlite3_column_int(statement, 2) != 0)
    }.first
  }

  private static func trimIncompleteUTF8Tail(_ data: Data) -> Data {
    guard !data.isEmpty, EventCodec.strictUTF8(data) == nil else { return data }
    var start = data.count - 1
    while start > 0 && data[start] & 0xc0 == 0x80 { start -= 1 }
    let first = data[start]
    let required: Int
    switch first {
    case 0xc2...0xdf: required = 2
    case 0xe0...0xef: required = 3
    case 0xf0...0xf4: required = 4
    default: return data
    }
    let count = data.count - start
    guard count < required, EventCodec.strictUTF8(Data(data.prefix(start))) != nil else {
      return data
    }
    if count > 1 {
      let second = data[start + 1]
      guard (0x80...0xbf).contains(second), !(first == 0xe0 && second < 0xa0),
        !(first == 0xed && second >= 0xa0), !(first == 0xf0 && second < 0x90),
        !(first == 0xf4 && second > 0x8f)
      else { return data }
    }
    return Data(data.prefix(start))
  }

  public func event(contentHash: String) throws -> StoredEvent? {
    // SQL bounds prevent corrupt or externally edited rows from materializing unbounded BLOBs.
    let results = try rows(
      """
      SELECT content_hash, data_type, substr(summary_display, 1, 512), (summary_truncated OR length(summary_display) > 512), timestamp,
             source_bundle_id, is_remote_clipboard, byte_count, is_pinned,
             event_data, display, compact_display, length(event_data), length(display), length(compact_display)
      FROM clipboard_events WHERE content_hash = ?
        AND length(event_data) <= 268435456 AND length(display) <= 1048576
        AND (compact_display IS NULL OR length(compact_display) <= 1048576)
      """, [.string(contentHash)]
    ) { statement in
      StoredEvent(
        item: summary(statement), eventData: blob(statement, 9), fullDisplay: blob(statement, 10),
        compactDisplay: sqlite3_column_type(statement, 11) == SQLITE_NULL
          ? nil : blob(statement, 11))
    }
    if results.isEmpty,
      try scalar(
        "SELECT COUNT(*) FROM clipboard_events WHERE content_hash = ?", [.string(contentHash)]) > 0
    {
      throw StorageError.invalidEvent
    }
    return results.first
  }

  @discardableResult public func setPinned(contentHash: String, pinned: Bool) throws -> Bool {
    try transaction {
      let group = try groupFilter(contentHash: contentHash)
      try run(
        "UPDATE clipboard_events SET is_pinned = ? WHERE \(group.sql)",
        [.int(pinned ? 1 : 0)] + group.args)
      let changed = sqlite3_changes(db) > 0
      if !pinned { try cleanup() }
      return changed
    }
  }

  @discardableResult public func delete(contentHash: String, allowPinned: Bool = true) throws
    -> Bool
  {
    try transaction {
      let group = try groupFilter(contentHash: contentHash)
      if !allowPinned,
        try scalar(
          "SELECT COUNT(*) FROM clipboard_events WHERE (\(group.sql)) AND is_pinned = 1", group.args
        ) > 0
      {
        return false
      }
      try run("DELETE FROM clipboard_events WHERE \(group.sql)", group.args)
      return sqlite3_changes(db) > 0
    }
  }

  public func clear(includePinned: Bool = false) throws {
    try transaction {
      try run("DELETE FROM clipboard_events\(includePinned ? "" : " WHERE is_pinned = 0")")
    }
  }

  public func setSetting(key: String, value: String) throws {
    guard Self.defaults[key] != nil else { throw StorageError.invalidSetting }
    switch key {
    case "max_items":
      guard let n = Int(value), (1...1_000).contains(n) else { throw StorageError.invalidSetting }
    case "menu_bar_item_limit":
      guard let n = Int(value), (0...1_000).contains(n) else { throw StorageError.invalidSetting }
    case "max_history_bytes":
      guard let n = Int64(value), n >= 0 else { throw StorageError.invalidSetting }
    case "max_event_bytes":
      guard let n = Int64(value), Self.validEventLimit(n) else { throw StorageError.invalidSetting }
    case "language":
      guard ["system", "en", "zh-CN", "zh-TW"].contains(value) else {
        throw StorageError.invalidSetting
      }
    case "theme":
      guard ["system", "light", "dark"].contains(value) else { throw StorageError.invalidSetting }
    default:
      guard ["true", "false", "1", "0"].contains(value) else { throw StorageError.invalidSetting }
    }
    try transaction {
      try run(
        "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
        [.string(key), .string(value)])
      if key == "max_items" || key == "max_history_bytes" { try cleanup() }
    }
  }

  @discardableResult public func insert(prepared: PreparedEvent) throws -> Bool {
    let current = try settings()
    guard prepared.eventData.count <= current.maxEventBytes else { return false }
    guard HistoryCursor.validHash(prepared.contentHash), prepared.display.count <= 1_048_576,
      prepared.summaryDisplay.count <= 512, (prepared.compactDisplay?.count ?? 0) <= 1_048_576,
      (prepared.sourceBundleID?.utf8.count ?? 0) <= 255, prepared.byteCount >= 0,
      prepared.compactMode == current.compactMode,
      prepared.byteCount
        == Int64(
          prepared.eventData.count + prepared.display.count + prepared.summaryDisplay.count
            + (prepared.compactDisplay?.count ?? 0) + (prepared.sourceBundleID?.utf8.count ?? 0))
    else { throw StorageError.invalidEvent }
    return try transaction {
      var oldHash = prepared.contentHash
      var timestamp: Int64?
      var pinned: Int64 = 0
      if prepared.compactMode {
        let matches = try rows(
          "SELECT content_hash, timestamp, is_pinned FROM clipboard_events WHERE compact_content_hash = ? ORDER BY timestamp DESC, content_hash ASC",
          [.string(prepared.contentHash)]
        ) { (text($0, 0), sqlite3_column_int64($0, 1), sqlite3_column_int64($0, 2)) }
        if let newest = matches.first {
          timestamp = newest.1
          pinned = matches.contains { $0.2 != 0 } ? 1 : 0
          oldHash =
            matches.contains { $0.0 == prepared.contentHash } ? prepared.contentHash : newest.0
          for match in matches where match.0 != oldHash {
            try run("DELETE FROM clipboard_events WHERE content_hash = ?", [.string(match.0)])
          }
        }
      } else {
        if let row = try rows(
          "SELECT timestamp, is_pinned FROM clipboard_events WHERE content_hash = ?",
          [.string(oldHash)], map: { (sqlite3_column_int64($0, 0), sqlite3_column_int64($0, 1)) }
        ).first {
          timestamp = row.0
          pinned = row.1
        }
      }
      let values: [Value] = [
        .string(prepared.contentHash), .data(prepared.eventData), .string(prepared.dataType),
        .data(prepared.display), .data(prepared.summaryDisplay),
        .int(prepared.summaryTruncated ? 1 : 0),
        prepared.compactContentHash.map(Value.string) ?? .null,
        prepared.compactDisplay.map(Value.data) ?? .null,
        prepared.sourceBundleID.map(Value.string) ?? .null,
        .int(prepared.isRemoteClipboard ? 1 : 0),
        .int(prepared.byteCount), .int(try timestamp ?? nextTimestamp()), .int(1), .int(pinned),
      ]
      if timestamp != nil {
        try run(
          """
          UPDATE clipboard_events SET content_hash = ?, event_data = ?, data_type = ?, display = ?,
              summary_display = ?, summary_truncated = ?, compact_content_hash = ?, compact_display = ?,
              source_bundle_id = ?, is_remote_clipboard = ?, byte_count = ?, timestamp = ?, metadata_version = ?, is_pinned = ?
          WHERE content_hash = ?
          """, values + [.string(oldHash)])
      } else {
        try run(
          "INSERT INTO clipboard_events (\(Self.eventColumns.joined(separator: ", "))) VALUES (\(Array(repeating: "?", count: 14).joined(separator: ", ")))",
          values)
      }
      try run(
        "DELETE FROM clipboard_event_search WHERE content_hash = ?", [.string(prepared.contentHash)]
      )
      try run(
        "INSERT INTO clipboard_event_search (content_hash, search_text, compact_search_text) VALUES (?, ?, ?)",
        [
          .string(prepared.contentHash), .string(prepared.searchText),
          .string(prepared.compactSearchText),
        ])
      try cleanup()
      return true
    }
  }

  public func moveToTop(contentHash: String) throws {
    try transaction {
      try run(
        "UPDATE clipboard_events SET timestamp = ? WHERE content_hash = ?",
        [.int(try nextTimestamp()), .string(contentHash)])
    }
  }

  /// Streams one consistent snapshot through an independent read-only connection.
  /// The callback must not invoke another transaction on this same connection.
  public func visitSnapshotRows(_ visitor: (HistorySnapshotRow) throws -> Void) throws {
    try transaction(write: false) {
      let compact = try settings().compactMode
      let invalidFilter =
        compact
        ? "compact_display IS NOT NULL AND length(compact_display) > 1048576"
        : "length(event_data) > 268435456 OR length(display) > 1048576"
      guard try scalar("SELECT COUNT(*) FROM clipboard_events WHERE \(invalidFilter)") == 0 else {
        throw StorageError.invalidEvent
      }
      let query: String
      if compact {
        query = """
          SELECT e.compact_content_hash, e.compact_display, e.timestamp, e.source_bundle_id, e.is_remote_clipboard
          FROM clipboard_events e WHERE \(Self.compactFilter) ORDER BY e.timestamp DESC, e.content_hash ASC
          """
      } else {
        query = """
          SELECT content_hash, event_data, data_type, display, timestamp, source_bundle_id, is_remote_clipboard
          FROM clipboard_events ORDER BY timestamp DESC, content_hash ASC
          """
      }
      let prepared = try statement(query, [])
      defer { sqlite3_finalize(prepared) }
      var rc = sqlite3_step(prepared)
      while rc == SQLITE_ROW {
        let row: HistorySnapshotRow
        if compact {
          let display = blob(prepared, 1)
          let source = sqlite3_column_type(prepared, 3) == SQLITE_NULL ? nil : text(prepared, 3)
          let remote = sqlite3_column_int(prepared, 4) != 0
          var flavors = [ClipboardRepresentation(type: EventClassifier.textType, data: display)]
          if let source {
            flavors.append(
              ClipboardRepresentation(type: PasteboardProtocol.sourceType, data: Data(source.utf8)))
          }
          if remote {
            flavors.append(
              ClipboardRepresentation(type: PasteboardProtocol.remoteType, data: Data()))
          }
          row = HistorySnapshotRow(
            contentHash: text(prepared, 0),
            eventData: try EventCodec.encode(
              ClipboardEvent(items: [ClipboardItem(dataList: flavors)])),
            dataType: "text", display: display, timestamp: sqlite3_column_int64(prepared, 2),
            sourceBundleID: source, isRemoteClipboard: remote)
        } else {
          row = HistorySnapshotRow(
            contentHash: text(prepared, 0), eventData: blob(prepared, 1),
            dataType: text(prepared, 2), display: blob(prepared, 3),
            timestamp: sqlite3_column_int64(prepared, 4),
            sourceBundleID: sqlite3_column_type(prepared, 5) == SQLITE_NULL
              ? nil : text(prepared, 5),
            isRemoteClipboard: sqlite3_column_int(prepared, 6) != 0)
        }
        try visitor(row)
        rc = sqlite3_step(prepared)
      }
      guard rc == SQLITE_DONE else { throw StorageError.database(rc) }
    }
  }

  /// Relocates a consistent snapshot using the original app's recovery commit protocol.
  public func moveStorage(to directory: URL) throws {
    guard !readOnly else { throw StorageError.readOnly }
    try PrivateStorage.ensureDirectory(directory)
    let destination = try PrivateStorage.canonicalDirectory(directory).appendingPathComponent(
      "clipecho.db")
    if destination == url { return }
    for suffix in ["", "-wal", "-shm", "-journal"] {
      guard
        try PrivateStorage.identityIfPresent(URL(fileURLWithPath: destination.path + suffix)) == nil
      else { throw StorageError.destinationExists }
    }
    let source = url
    guard let sourceIdentity = try PrivateStorage.identityIfPresent(source) else {
      throw StorageError.moveFailed
    }
    // An active original app prevents the checkpoint/journal switch; SQLite then refuses the move.
    try run("PRAGMA wal_checkpoint(TRUNCATE)")
    try run("PRAGMA journal_mode = DELETE")
    try PrivateStorage.createFile(destination)
    var replacement: SQLiteStore?
    var recoverySaved = false
    do {
      try copySnapshot(to: destination)
      replacement = try SQLiteStore(url: destination, locator: locator)
      guard try replacement?.scalar("PRAGMA quick_check", stringExpected: "ok") == 1 else {
        throw StorageError.moveFailed
      }
      try locator.saveRecovery(source: source, destination: destination)
      recoverySaved = true
      try locator.save(directory: destination.deletingLastPathComponent())
      guard try PrivateStorage.identityIfPresent(source) == sourceIdentity else {
        throw StorageError.unsafePath
      }
      try FileManager.default.removeItem(at: source)
      // Source removal is the commit point. No fallible operation follows it.
      let oldConnection = db
      db = replacement?.db
      replacement?.db = nil
      url = destination
      if let oldConnection { sqlite3_close(oldConnection) }
      for suffix in ["-wal", "-shm", "-journal"] {
        try? FileManager.default.removeItem(atPath: source.path + suffix)
      }
      locator.finishRecovery()
    } catch {
      replacement = nil
      if recoverySaved {
        do {
          try locator.save(directory: source.deletingLastPathComponent())
          locator.finishRecovery()
        } catch {
          // Keep the recovery and snapshot when config rollback is blocked.
          throw StorageError.moveFailed
        }
      }
      for suffix in ["", "-wal", "-shm", "-journal"] {
        try? FileManager.default.removeItem(atPath: destination.path + suffix)
      }
      try? run("PRAGMA journal_mode = WAL")
      throw error is StorageError ? error : StorageError.moveFailed
    }
  }

  private func initialize() throws {
    let version = try scalar("PRAGMA user_version")
    guard version == 0 || version == 3 || version == 4 else {
      throw StorageError.unsupportedSchema(version)
    }
    let exists =
      try scalar(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'clipboard_events'") > 0
    if version == 0 && exists { throw StorageError.unsupportedSchema(0) }
    if version == 0,
      try scalar(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'") > 0
    {
      throw StorageError.unsupportedSchema(0)
    }
    guard version == 0 || exists else { throw StorageError.invalidConfiguration }
    if readOnly {
      guard version == 4 && exists else { throw StorageError.unsupportedSchema(version) }
      try validateSchema()
      return
    }
    if exists {
      try validateAuthoritativeSchema(version: version)
    }
    _ = try PrivateStorage.identityIfPresent(url, tighten: true)
    try protectSidecars()
    try transaction {
      try run("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
      try run(
        "CREATE TABLE IF NOT EXISTS app_metadata (key TEXT PRIMARY KEY, value INTEGER NOT NULL)")
      if !exists {
        try run(
          """
          CREATE TABLE clipboard_events (
              content_hash TEXT PRIMARY KEY, event_data BLOB NOT NULL, data_type TEXT NOT NULL,
              display BLOB NOT NULL, summary_display BLOB NOT NULL, summary_truncated INTEGER NOT NULL,
              compact_content_hash TEXT, compact_display BLOB, source_bundle_id TEXT,
              is_remote_clipboard INTEGER NOT NULL, byte_count INTEGER NOT NULL, timestamp INTEGER NOT NULL,
              metadata_version INTEGER NOT NULL, is_pinned INTEGER NOT NULL DEFAULT 0 CHECK (is_pinned IN (0, 1)))
          """)
      } else if version == 3 {
        try run(
          "ALTER TABLE clipboard_events ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0 CHECK (is_pinned IN (0, 1))"
        )
      }
      for (key, value) in Self.defaults {
        try run(
          "INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)",
          [.string(key), .string(value)])
      }
      try run(
        "CREATE INDEX IF NOT EXISTS idx_clipboard_events_pinned ON clipboard_events(is_pinned DESC, timestamp DESC, content_hash ASC)"
      )
      try run(
        "CREATE INDEX IF NOT EXISTS idx_clipboard_events_timestamp ON clipboard_events(timestamp DESC, content_hash ASC)"
      )
      try run(
        "CREATE INDEX IF NOT EXISTS idx_clipboard_events_compact ON clipboard_events(compact_content_hash, timestamp DESC, content_hash ASC) WHERE compact_content_hash IS NOT NULL"
      )
      let searchDefinition = try rows(
        "SELECT sql FROM sqlite_master WHERE name = 'clipboard_event_search'"
      ) { text($0, 0) }.first
      let normalizedSearch = searchDefinition?.lowercased().filter { !$0.isWhitespace } ?? ""
      let searchExists =
        normalizedSearch.contains("usingfts5(") && normalizedSearch.contains("tokenize='trigram'")
      if searchDefinition != nil && !searchExists {
        try run("DROP TRIGGER IF EXISTS clipboard_events_search_after_delete")
        try run("DROP TRIGGER IF EXISTS clipboard_events_search_after_update")
        try run("DROP TABLE clipboard_event_search")
      }
      try run(
        "CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_event_search USING fts5(content_hash UNINDEXED, search_text, compact_search_text, tokenize = 'trigram')"
      )
      try run(
        """
        CREATE TRIGGER IF NOT EXISTS clipboard_events_search_after_delete AFTER DELETE ON clipboard_events
        BEGIN DELETE FROM clipboard_event_search WHERE content_hash = OLD.content_hash; END
        """)
      try run(
        """
        CREATE TRIGGER IF NOT EXISTS clipboard_events_search_after_update
        AFTER UPDATE OF content_hash, data_type, display, compact_display ON clipboard_events
        BEGIN DELETE FROM clipboard_event_search WHERE content_hash = OLD.content_hash; END
        """)
      let searchCount = try scalar("SELECT COUNT(*) FROM clipboard_event_search")
      let eventCount = try scalar("SELECT COUNT(*) FROM clipboard_events")
      let missingSearchRows = try scalar(
        "SELECT COUNT(*) FROM (SELECT content_hash FROM clipboard_events EXCEPT SELECT content_hash FROM clipboard_event_search)"
      )
      if !searchExists || searchCount != eventCount || missingSearchRows > 0 {
        // No event decode: persisted displays already carry the current classifier's text projection.
        try run("DELETE FROM clipboard_event_search")
        let entries = try rows(
          "SELECT content_hash, data_type, display, compact_display FROM clipboard_events WHERE length(display) <= 1048576 AND (compact_display IS NULL OR length(compact_display) <= 1048576)"
        ) { statement -> (String, String, String) in
          let searchable = EventClassifier.searchableText(
            dataType: text(statement, 1), display: blob(statement, 2))
          return (
            text(statement, 0), searchable, EventClassifier.searchablePlainText(blob(statement, 3))
          )
        }
        for entry in entries {
          try run(
            "INSERT INTO clipboard_event_search VALUES (?, ?, ?)",
            [.string(entry.0), .string(entry.1), .string(entry.2)])
        }
      }
      try run(
        "INSERT OR IGNORE INTO app_metadata (key, value) VALUES ('classifier_metadata_version', 1), ('search_index_version', 1)"
      )
      try run("PRAGMA user_version = 4")
      try validateSchema()
      try cleanup()
    }
  }

  private func copySnapshot(to destination: URL) throws {
    // Apple's system SQLite refuses VACUUM INTO even an empty pre-created file.
    // Online backup lets us keep exclusive 0600 creation without changing process umask.
    guard let identity = try PrivateStorage.identityIfPresent(destination) else {
      throw StorageError.moveFailed
    }
    var target: OpaquePointer?
    let openResult = sqlite3_open_v2(
      destination.path, &target,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
    guard openResult == SQLITE_OK, let target else {
      if let target { sqlite3_close(target) }
      throw StorageError.database(openResult)
    }
    defer { sqlite3_close(target) }
    guard try PrivateStorage.identityIfPresent(destination) == identity else {
      throw StorageError.unsafePath
    }
    guard let backup = sqlite3_backup_init(target, "main", db, "main") else {
      throw StorageError.database(sqlite3_errcode(target))
    }
    let stepResult = sqlite3_backup_step(backup, -1)
    let finishResult = sqlite3_backup_finish(backup)
    guard stepResult == SQLITE_DONE else { throw StorageError.database(stepResult) }
    guard finishResult == SQLITE_OK else { throw StorageError.database(finishResult) }
    guard try PrivateStorage.identityIfPresent(destination) == identity else {
      throw StorageError.unsafePath
    }
  }

  private func validateSchema() throws {
    try validateAuthoritativeSchema(version: 4)
    guard
      try scalar(
        "SELECT COUNT(*) FROM sqlite_master WHERE name IN ('settings', 'app_metadata', 'clipboard_event_search')"
      ) == 3
    else { throw StorageError.invalidConfiguration }
    let searchDefinition =
      try rows("SELECT sql FROM sqlite_master WHERE name = 'clipboard_event_search'") {
        text($0, 0)
      }.first ?? ""
    let normalizedSearch = searchDefinition.lowercased().filter { !$0.isWhitespace }
    guard normalizedSearch.contains("usingfts5("), normalizedSearch.contains("tokenize='trigram'")
    else { throw StorageError.invalidConfiguration }
    _ = try rows("SELECT key, value FROM settings LIMIT 0") { _ in 0 }
    _ = try rows(
      "SELECT content_hash, search_text, compact_search_text FROM clipboard_event_search LIMIT 0"
    ) { _ in 0 }
  }

  private func validateAuthoritativeSchema(version: Int64) throws {
    let columns = try rows("PRAGMA table_info(clipboard_events)") {
      (text($0, 1), text($0, 2).uppercased(), sqlite3_column_int($0, 3), sqlite3_column_int($0, 5))
    }
    let expectedNames = version == 3 ? Array(Self.eventColumns.dropLast()) : Self.eventColumns
    let expectedTypes = [
      "TEXT", "BLOB", "TEXT", "BLOB", "BLOB", "INTEGER", "TEXT", "BLOB", "TEXT", "INTEGER",
      "INTEGER", "INTEGER", "INTEGER", "INTEGER",
    ]
    let optional = Set([0, 6, 7, 8])
    guard columns.count == expectedNames.count else { throw StorageError.invalidConfiguration }
    for (index, column) in columns.enumerated() {
      guard column.0 == expectedNames[index], column.1 == expectedTypes[index],
        column.2 == (optional.contains(index) ? 0 : 1), column.3 == (index == 0 ? 1 : 0)
      else { throw StorageError.invalidConfiguration }
    }
    guard
      try scalar(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('settings', 'app_metadata')"
      ) == 2
    else { throw StorageError.invalidConfiguration }
    let versions = try rows(
      "SELECT key, value FROM app_metadata WHERE key IN ('classifier_metadata_version', 'search_index_version')"
    ) { (text($0, 0), sqlite3_column_int64($0, 1)) }
    guard versions.count == 2, versions.allSatisfy({ $0.1 == 1 }),
      try scalar("SELECT COUNT(*) FROM clipboard_events WHERE metadata_version != 1") == 0
    else { throw StorageError.unsupportedSchema(version) }
    guard
      try scalar(
        """
        SELECT COUNT(*) FROM clipboard_events WHERE content_hash IS NULL OR length(content_hash) != 64
        OR content_hash GLOB '*[^0-9a-f]*' OR byte_count < 0 OR is_remote_clipboard NOT IN (0, 1)
        \(version == 4 ? "OR is_pinned NOT IN (0, 1)" : "")
        """) == 0
    else { throw StorageError.invalidConfiguration }
  }

  private func cleanup() throws {
    let limits = try settings()
    let count = try scalar("SELECT COUNT(*) FROM clipboard_events")
    if count > limits.maxItems {
      try run(
        "DELETE FROM clipboard_events WHERE content_hash IN (SELECT content_hash FROM clipboard_events WHERE is_pinned = 0 ORDER BY timestamp ASC, content_hash DESC LIMIT ?)",
        [.int(count - Int64(limits.maxItems))])
    }
    var excess =
      try scalar("SELECT COALESCE(SUM(byte_count), 0) FROM clipboard_events")
      - limits.maxHistoryBytes
    if excess > 0 {
      let oldest = try rows(
        "SELECT content_hash, byte_count FROM clipboard_events WHERE is_pinned = 0 ORDER BY timestamp ASC, content_hash DESC"
      ) { (text($0, 0), sqlite3_column_int64($0, 1)) }
      for row in oldest {
        try run("DELETE FROM clipboard_events WHERE content_hash = ?", [.string(row.0)])
        excess -= max(0, row.1)
        if excess <= 0 { break }
      }
    }
  }

  private func groupFilter(contentHash: String) throws -> (sql: String, args: [Value]) {
    if try settings().compactMode {
      return (
        "content_hash = ? OR compact_content_hash = (SELECT compact_content_hash FROM clipboard_events WHERE content_hash = ?)",
        [.string(contentHash), .string(contentHash)]
      )
    }
    return ("content_hash = ?", [.string(contentHash)])
  }
  private func nextTimestamp() throws -> Int64 {
    let maximum = try scalar("SELECT COALESCE(MAX(timestamp), 0) FROM clipboard_events")
    guard maximum < Int64.max else { throw StorageError.invalidEvent }
    return max(Int64(Date().timeIntervalSince1970 * 1_000), maximum + 1)
  }
  private func pinExpression(compact: Bool) -> String {
    compact
      ? "(SELECT MAX(p.is_pinned) FROM clipboard_events p WHERE p.compact_content_hash = e.compact_content_hash)"
      : "e.is_pinned"
  }
  private static func validEventLimit(_ value: Int64) -> Bool {
    value >= 1_048_576 && value <= 268_435_456 && value % 1_048_576 == 0
  }
  private func protectSidecars() throws {
    for suffix in ["-wal", "-shm", "-journal"] {
      _ = try PrivateStorage.identityIfPresent(
        URL(fileURLWithPath: url.path + suffix), tighten: true)
    }
  }
  private func transaction<T>(write: Bool = true, _ body: () throws -> T) throws -> T {
    if write && readOnly { throw StorageError.readOnly }
    try run(write ? "BEGIN IMMEDIATE" : "BEGIN")
    do {
      let value = try body()
      if write { try protectSidecars() }
      try run("COMMIT")
      return value
    } catch {
      try? run("ROLLBACK")
      throw error
    }
  }
  private enum Value {
    case string(String)
    case data(Data)
    case int(Int64)
    case null
  }
  private func statement(_ sql: String, _ args: [Value]) throws -> OpaquePointer {
    var prepared: OpaquePointer?
    let rc = sqlite3_prepare_v2(db, sql, -1, &prepared, nil)
    guard rc == SQLITE_OK, let prepared else { throw StorageError.database(rc) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (offset, value) in args.enumerated() {
      let index = Int32(offset + 1)
      let result: Int32
      switch value {
      case .string(let value):
        guard let byteCount = Int32(exactly: value.utf8.count) else {
          sqlite3_finalize(prepared)
          throw StorageError.invalidEvent
        }
        // An explicit byte length preserves an empty source marker and embedded UTF-8 NULs.
        result = sqlite3_bind_text(prepared, index, value, byteCount, transient)
      case .data(let value):
        if value.isEmpty {
          result = sqlite3_bind_zeroblob(prepared, index, 0)
        } else {
          result = value.withUnsafeBytes {
            sqlite3_bind_blob(prepared, index, $0.baseAddress, Int32(value.count), transient)
          }
        }
      case .int(let value): result = sqlite3_bind_int64(prepared, index, value)
      case .null: result = sqlite3_bind_null(prepared, index)
      }
      guard result == SQLITE_OK else {
        sqlite3_finalize(prepared)
        throw StorageError.database(result)
      }
    }
    return prepared
  }
  private func run(_ sql: String, _ args: [Value] = []) throws {
    let prepared = try statement(sql, args)
    defer { sqlite3_finalize(prepared) }
    var rc = sqlite3_step(prepared)
    while rc == SQLITE_ROW { rc = sqlite3_step(prepared) }
    guard rc == SQLITE_DONE else { throw StorageError.database(rc) }
  }
  private func rows<T>(_ sql: String, _ args: [Value] = [], map: (OpaquePointer) throws -> T) throws
    -> [T]
  {
    let prepared = try statement(sql, args)
    defer { sqlite3_finalize(prepared) }
    var values: [T] = []
    var rc = sqlite3_step(prepared)
    while rc == SQLITE_ROW {
      values.append(try map(prepared))
      rc = sqlite3_step(prepared)
    }
    guard rc == SQLITE_DONE else { throw StorageError.database(rc) }
    return values
  }
  private func scalar(_ sql: String, _ args: [Value] = []) throws -> Int64 {
    try rows(sql, args) { sqlite3_column_int64($0, 0) }.first ?? 0
  }
  private func scalar(_ sql: String, stringExpected: String) throws -> Int64 {
    try rows(sql) { text($0, 0) }.allSatisfy { $0 == stringExpected } ? 1 : 0
  }
  private func summary(_ statement: OpaquePointer) -> HistoryItem {
    HistoryItem(
      contentHash: text(statement, 0), dataType: text(statement, 1), display: blob(statement, 2),
      displayTruncated: sqlite3_column_int(statement, 3) != 0,
      timestamp: sqlite3_column_int64(statement, 4),
      sourceBundleID: sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : text(statement, 5),
      isRemoteClipboard: sqlite3_column_int(statement, 6) != 0,
      byteCount: max(0, sqlite3_column_int64(statement, 7)),
      isPinned: sqlite3_column_int(statement, 8) != 0,
      searchPreview: sqlite3_column_count(statement) == 10
        && sqlite3_column_type(statement, 9) != SQLITE_NULL ? text(statement, 9) : nil)
  }
  private func sqlLiteral(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
  }
}

private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
  guard let bytes = sqlite3_column_text(statement, index) else { return "" }
  return String(
    decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, index))),
    as: UTF8.self)
}
private func blob(_ statement: OpaquePointer, _ index: Int32) -> Data {
  guard let bytes = sqlite3_column_blob(statement, index) else { return Data() }
  return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
}
