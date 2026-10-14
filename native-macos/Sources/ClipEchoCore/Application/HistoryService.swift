import Foundation

public struct HistorySnapshot: Sendable {
  public let settings: AppSettings
  public let stats: HistoryStats
  public let storageURL: URL
}

/// A serial actor owns the connection, orders mutations, and keeps disk work off the UI actor.
/// The composition root transfers exclusive ownership of an adapter into this actor.
public actor HistoryService {
  private let storage: any HistoryStorage
  public init(storage: sending any HistoryStorage) { self.storage = storage }

  public func snapshot() throws -> HistorySnapshot {
    HistorySnapshot(
      settings: try storage.settings(), stats: try storage.stats(), storageURL: storage.url)
  }
  public func settings() throws -> AppSettings { try storage.settings() }
  public func stats() throws -> HistoryStats { try storage.stats() }
  public func page(cursor: HistoryCursor? = nil, limit: Int = 50, query: String = "") throws
    -> HistoryPage
  {
    try storage.page(cursor: cursor, limit: limit, query: query)
  }
  public func event(contentHash: String) throws -> StoredEvent? {
    try storage.event(contentHash: contentHash)
  }
  public func trayItems(limit: Int = 0) throws -> [HistoryItem] {
    try storage.trayItems(limit: limit)
  }
  public func trayPreview(contentHash: String, limit: Int = 65_536) throws -> Data? {
    try storage.trayPreview(contentHash: contentHash, limit: limit)
  }
  public func trayPreviewDetails(contentHash: String, limit: Int = 65_536) throws -> TrayPreview? {
    try storage.trayPreviewDetails(contentHash: contentHash, limit: limit)
  }
  public func togglePin(_ item: HistoryItem) throws {
    _ = try storage.setPinned(contentHash: item.contentHash, pinned: !item.isPinned)
  }
  public func delete(_ item: HistoryItem) throws {
    _ = try storage.delete(contentHash: item.contentHash, allowPinned: item.isPinned)
  }
  public func clear(includePinned: Bool = false) throws {
    try storage.clear(includePinned: includePinned)
  }
  public func setSetting(key: String, value: String) throws {
    try storage.setSetting(key: key, value: value)
  }
  public func insert(prepared: PreparedEvent) throws { _ = try storage.insert(prepared: prepared) }
  public func moveToTop(contentHash: String) throws {
    try storage.moveToTop(contentHash: contentHash)
  }
  public func moveStorage(to directory: URL) throws { try storage.moveStorage(to: directory) }
}
