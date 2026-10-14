import Foundation
import Testing
@testable import ClipEchoCore

@Suite struct HistoryServiceTests {
    @Test func concurrentCaptureUsesOneRepositoryAndStablePages() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("clipecho-service-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let history = HistoryService(storage: try SQLiteStore(url: root.appendingPathComponent("clipecho.db"), locator: StorageLocator(root: root)))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<75 {
                let event = ClipboardEvent(items: [ClipboardItem(dataList: [ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("Synthetic service event \(index)".utf8))])])
                let prepared = try #require(EventClassifier.prepare(event: event, compactMode: false))
                group.addTask { try await history.insert(prepared: prepared) }
            }
            try await group.waitForAll()
        }
        let snapshot = try await history.snapshot()
        #expect(snapshot.stats.totalItems == 75)
        let first = try await history.page(limit: 50)
        let next = try #require(first.nextCursor)
        let second = try await history.page(cursor: next, limit: 50)
        #expect(first.items.count == 50)
        #expect(second.items.count == 25)
        let items = first.items + second.items
        #expect(Set(items.map(\.contentHash)).count == 75)
        #expect(Set(items.map(\.timestamp)).count == 75)
        #expect(items.map(\.timestamp) == items.map(\.timestamp).sorted(by: >))
        let oldest = try #require(items.last)
        try await history.togglePin(oldest)
        try await history.clear()
        #expect(try await history.stats().totalItems == 1)
        #expect(try await history.page().items.first?.contentHash == oldest.contentHash)
    }
}
