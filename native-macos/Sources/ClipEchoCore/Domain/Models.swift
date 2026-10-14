import Foundation

public struct HistoryItem: Identifiable, Equatable, Sendable {
  public let contentHash: String
  public let dataType: String
  public let display: Data
  public let displayTruncated: Bool
  public let timestamp: Int64
  public let sourceBundleID: String?
  public let isRemoteClipboard: Bool
  public let byteCount: Int64
  public let isPinned: Bool
  public let searchPreview: String?
  public var id: String { contentHash }
  public var displayText: String { String(decoding: display, as: UTF8.self) }
  public var date: Date { Date(timeIntervalSince1970: Double(timestamp) / 1_000) }

  public init(
    contentHash: String, dataType: String, display: Data, displayTruncated: Bool,
    timestamp: Int64, sourceBundleID: String?, isRemoteClipboard: Bool,
    byteCount: Int64, isPinned: Bool, searchPreview: String? = nil
  ) {
    self.contentHash = contentHash
    self.dataType = dataType
    self.display = display
    self.displayTruncated = displayTruncated
    self.timestamp = timestamp
    self.sourceBundleID = sourceBundleID
    self.isRemoteClipboard = isRemoteClipboard
    self.byteCount = byteCount
    self.isPinned = isPinned
    self.searchPreview = searchPreview
  }
}

public struct HistoryCursor: Equatable, Sendable {
  public let isPinned: Bool
  public let timestamp: Int64
  public let contentHash: String
  public init(isPinned: Bool, timestamp: Int64, contentHash: String) {
    self.isPinned = isPinned
    self.timestamp = timestamp
    self.contentHash = contentHash
  }
  public init(encoded: String) throws {
    let parts = encoded.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 4, parts[0] == "v2", ["0", "1"].contains(String(parts[1])),
      let timestamp = Int64(parts[2]), Self.validHash(String(parts[3]))
    else {
      throw StorageError.invalidCursor
    }
    self.init(isPinned: parts[1] == "1", timestamp: timestamp, contentHash: String(parts[3]))
  }
  public var encoded: String { "v2:\(isPinned ? 1 : 0):\(timestamp):\(contentHash)" }
  static func validHash(_ hash: String) -> Bool {
    hash.utf8.count == 64
      && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}

public struct HistoryPage: Equatable, Sendable {
  public let items: [HistoryItem]
  public let nextCursor: HistoryCursor?
  public let hasMore: Bool
  public let totalCount: Int64
  public let totalBytes: Int64
}

public struct TrayPreview: Equatable, Sendable {
  public let dataType: String
  public let display: Data
  public let truncated: Bool
  public init(dataType: String, display: Data, truncated: Bool) {
    self.dataType = dataType
    self.display = display
    self.truncated = truncated
  }
}

public struct StoredEvent: Sendable {
  public let item: HistoryItem
  public let eventData: Data
  public let fullDisplay: Data
  public let compactDisplay: Data?
  public var sourceBundleID: String? { item.sourceBundleID }
  public var isRemoteClipboard: Bool { item.isRemoteClipboard }
}

public struct AppSettings: Equatable, Sendable {
  public var maxItems: Int = 100
  public var maxHistoryBytes: Int64 = 256 * 1_024 * 1_024
  public var maxEventBytes: Int64 = 32 * 1_024 * 1_024
  public var showInMenuBar: Bool = true
  public var menuBarItemLimit: Int = 0
  public var moveRestoredItemToTop: Bool = false
  public var compactMode: Bool = false
  public var language: String = "system"
  public var theme: String = "system"
  public init() {}
}

public struct HistoryStats: Equatable, Sendable {
  public let totalItems: Int64
  public let totalBytes: Int64
  public let compactVisibleItems: Int64
}

public struct HistorySnapshotRow: Sendable {
  public let contentHash: String
  public let eventData: Data
  public let dataType: String
  public let display: Data
  public let timestamp: Int64
  public let sourceBundleID: String?
  public let isRemoteClipboard: Bool
}

public enum StorageError: Error, LocalizedError, Equatable {
  case inaccessible, unsafePath, invalidConfiguration
  case unsupportedSchema(Int64)
  case invalidSetting, invalidCursor, invalidQuery, invalidEvent, readOnly
  case database(Int32)
  case databaseOpen(Int32, Int32)
  case destinationExists, moveFailed
  public var errorDescription: String? {
    switch self {
    case .inaccessible: "Clipboard storage cannot be accessed."
    case .unsafePath: "Clipboard storage must be a private file owned by your account."
    case .invalidConfiguration: "The saved clipboard storage location is invalid or unavailable."
    case .unsupportedSchema(let version):
      "Clipboard database version \(version) is unsupported. Open it with the existing app before trying again."
    case .invalidSetting: "The setting value is outside the supported range."
    case .invalidCursor: "The history page cursor is invalid."
    case .invalidQuery: "The search text is invalid or too long."
    case .invalidEvent: "The clipboard event exceeds supported limits or has invalid metadata."
    case .readOnly: "Clipboard storage is open for inspection only."
    case .database(let code): "Clipboard database operation failed (SQLite \(code))."
    case .databaseOpen(let code, let systemErrno):
      "Clipboard database could not be opened (SQLite \(code), system \(systemErrno))."
    case .destinationExists: "A clipboard database or SQLite sidecar already exists in that folder."
    case .moveFailed: "The clipboard storage move could not be completed."
    }
  }
}
