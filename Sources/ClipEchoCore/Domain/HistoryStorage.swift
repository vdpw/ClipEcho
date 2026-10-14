import Foundation

/// Persistence port used by the application service. Implementations remain actor-confined.
public protocol HistoryStorage: AnyObject {
  var url: URL { get }
  var readOnly: Bool { get }
  func settings() throws -> AppSettings
  func stats() throws -> HistoryStats
  func page(cursor: HistoryCursor?, limit: Int, query: String) throws -> HistoryPage
  func event(contentHash: String) throws -> StoredEvent?
  func trayItems(limit: Int) throws -> [HistoryItem]
  func trayPreview(contentHash: String, limit: Int) throws -> Data?
  func trayPreviewDetails(contentHash: String, limit: Int) throws -> TrayPreview?
  func setPinned(contentHash: String, pinned: Bool) throws -> Bool
  func delete(contentHash: String, allowPinned: Bool) throws -> Bool
  func clear(includePinned: Bool) throws
  func setSetting(key: String, value: String) throws
  func insert(prepared: PreparedEvent) throws -> Bool
  func moveToTop(contentHash: String) throws
  func moveStorage(to directory: URL) throws
}
