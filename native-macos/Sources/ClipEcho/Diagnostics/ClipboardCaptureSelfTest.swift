import AppKit
import ClipEchoCore

/// Real pasteboard generations with synthetic public/private Chrome formats.
/// Named pasteboards keep the user's general clipboard and history untouched.
@MainActor
enum ClipboardCaptureSelfTest {
    enum Failure: Error { case assertion(Int) }

    private static let chromiumToken = NSPasteboard.PasteboardType("org.chromium.internal.source-rfh-token")
    private static let chromiumURL = NSPasteboard.PasteboardType("org.chromium.source-url")
    private static let browserTypes: [NSPasteboard.PasteboardType] = [.html, .string, chromiumToken, chromiumURL]

    private static func require(_ condition: Bool, line: Int = #line) throws {
        if !condition { throw Failure.assertion(line) }
    }

    private static func writeBrowserBody(_ text: String, to pasteboard: NSPasteboard) throws {
        try require(pasteboard.setString(text, forType: .string))
        try require(pasteboard.setString("<p>\(text)</p>", forType: .html))
        try require(pasteboard.setData(Data([0, 1, 2]), forType: chromiumToken))
        try require(pasteboard.setString("https://example.test/synthetic", forType: chromiumURL))
    }

    static func run() async throws {
        for compactMode in [false, true] {
            try await delayedBrowserBody(compactMode: compactMode)
            try await timerCapturesDelayedBrowserBody(compactMode: compactMode)
            try await newerGenerationReplacesPendingRead(compactMode: compactMode)
            try await retriesAreBounded(compactMode: compactMode)
            try await privacyStillConsumesWithoutReadingBody(compactMode: compactMode)
            try await readyPlainTextDoesNotWaitForOptionalHTML(compactMode: compactMode)
            try await richBrowserSelectionIsPersisted(compactMode: compactMode)
        }
        FileHandle.standardOutput.write(Data("Clipboard capture self-test passed: delayed same-generation Chrome formats through manual polls and the production timer in full/compact modes, no duplicate captures, newest-generation replacement, bounded retries, privacy, immediate plain-text fallback and rich selections with inline images through capture/storage/restore. Named synthetic pasteboards.\n".utf8))
    }

    private static func delayedBrowserBody(compactMode: Bool) async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var settings = AppSettings(); settings.compactMode = compactMode
        var captures: [PreparedEvent] = []
        var errors = 0
        let monitor = ClipboardMonitor(pasteboard: pasteboard, settingsProvider: { settings },
            onCapture: { captures.append($0) }, onError: { _ in errors += 1 })
        defer { monitor.stop() }
        let declared = pasteboard.declareTypes(browserTypes, owner: nil)
        try require(pasteboard.pasteboardItems?.count == 1)
        try require(pasteboard.data(forType: .string) == nil)
        await monitor.pollNow()
        try require(captures.isEmpty)
        let text = "Synthetic browser Cmd+C fixture 浏览器 😀"
        try writeBrowserBody(text, to: pasteboard)
        try require(pasteboard.changeCount == declared)
        await monitor.pollNow()
        try require(captures.count == 1 && errors == 0)
        try require(captures[0].display == Data(text.utf8))
        try require(captures[0].dataType == (compactMode ? "text" : "html"))
        try require(captures[0].sourceBundleID == nil)
        await monitor.pollNow()
        await monitor.pollNow()
        try require(captures.count == 1)
    }

    private static func timerCapturesDelayedBrowserBody(compactMode: Bool) async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var settings = AppSettings(); settings.compactMode = compactMode
        var captures: [PreparedEvent] = []
        var errors = 0
        let monitor = ClipboardMonitor(pasteboard: pasteboard, settingsProvider: { settings },
            onCapture: { captures.append($0) }, onError: { _ in errors += 1 })
        monitor.start()
        defer { monitor.stop() }
        let declared = pasteboard.declareTypes(browserTypes, owner: nil)
        // Let the ordinary 300 ms timer observe this generation before its body
        // becomes available. No explicit pollNow calls occur in this scenario.
        try await Task.sleep(for: .milliseconds(450))
        try require(captures.isEmpty && errors == 0)
        let text = "Synthetic delayed timer browser capture"
        try writeBrowserBody(text, to: pasteboard)
        try require(pasteboard.changeCount == declared)
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        while captures.isEmpty && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(captures.count == 1 && errors == 0)
        try require(captures[0].display == Data(text.utf8))
        try await Task.sleep(for: .milliseconds(350))
        try require(captures.count == 1 && errors == 0)
    }

    private static func newerGenerationReplacesPendingRead(compactMode: Bool) async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var settings = AppSettings(); settings.compactMode = compactMode
        var captures: [PreparedEvent] = []
        var errors = 0
        let monitor = ClipboardMonitor(pasteboard: pasteboard, settingsProvider: { settings },
            onCapture: { captures.append($0) }, onError: { _ in errors += 1 })
        defer { monitor.stop() }
        let unfinished = pasteboard.declareTypes(browserTypes, owner: nil)
        await monitor.pollNow()
        pasteboard.clearContents()
        let text = "Synthetic replacement generation"
        try require(pasteboard.setString(text, forType: .string))
        try require(pasteboard.changeCount != unfinished)
        await monitor.pollNow()
        try require(captures.count == 1 && errors == 0)
        try require(captures[0].display == Data(text.utf8))
    }

    private static func retriesAreBounded(compactMode: Bool) async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var settings = AppSettings(); settings.compactMode = compactMode
        var captures: [PreparedEvent] = []
        var errors = 0
        let monitor = ClipboardMonitor(pasteboard: pasteboard, settingsProvider: { settings },
            onCapture: { captures.append($0) }, onError: { _ in errors += 1 })
        defer { monitor.stop() }
        let expired = pasteboard.declareTypes([.string], owner: nil)
        for _ in 0..<ClipboardMonitor.maxReadAttempts { await monitor.pollNow() }
        try require(captures.isEmpty && errors == 0)
        try require(pasteboard.setString("Synthetic body beyond the retry budget", forType: .string))
        try require(pasteboard.changeCount == expired)
        await monitor.pollNow()
        try require(captures.isEmpty)
        pasteboard.clearContents()
        try require(pasteboard.setString("Synthetic next generation after timeout", forType: .string))
        await monitor.pollNow()
        try require(captures.count == 1 && errors == 0)
    }

    private static func privacyStillConsumesWithoutReadingBody(compactMode: Bool) async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var settings = AppSettings(); settings.compactMode = compactMode
        var captures = 0
        var errors = 0
        let monitor = ClipboardMonitor(pasteboard: pasteboard, settingsProvider: { settings },
            onCapture: { _ in captures += 1 }, onError: { _ in errors += 1 })
        defer { monitor.stop() }
        let privateGeneration = pasteboard.declareTypes(browserTypes + [NSPasteboard.PasteboardType(PasteboardProtocol.concealedType)], owner: nil)
        await monitor.pollNow()
        try writeBrowserBody("Synthetic concealed value", to: pasteboard)
        try require(pasteboard.changeCount == privateGeneration)
        for _ in 0...ClipboardMonitor.maxReadAttempts { await monitor.pollNow() }
        try require(captures == 0 && errors == 0)
        pasteboard.clearContents()
        try require(pasteboard.setString("Synthetic next ordinary copy", forType: .string))
        await monitor.pollNow()
        try require(captures == 1 && errors == 0)
    }

    private static func readyPlainTextDoesNotWaitForOptionalHTML(compactMode: Bool) async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var settings = AppSettings(); settings.compactMode = compactMode
        var captures: [PreparedEvent] = []
        var errors = 0
        let monitor = ClipboardMonitor(pasteboard: pasteboard, settingsProvider: { settings },
            onCapture: { captures.append($0) }, onError: { _ in errors += 1 })
        defer { monitor.stop() }
        pasteboard.declareTypes(browserTypes, owner: nil)
        let text = "Synthetic immediately available plain text"
        try require(pasteboard.setString(text, forType: .string))
        try require(pasteboard.data(forType: .html) == nil)
        await monitor.pollNow()
        try require(captures.count == 1 && errors == 0)
        try require(captures[0].dataType == "text" && captures[0].display == Data(text.utf8))
    }

    private static func richBrowserSelectionIsPersisted(compactMode: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipecho-rich-browser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("clipecho.db")
        let history = try await Task.detached {
            HistoryService(storage: try SQLiteStore(url: databaseURL))
        }.value
        try await history.setSetting(key: "compact_mode", value: compactMode ? "true" : "false")
        let settings = try await history.settings()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var captures: [PreparedEvent] = []
        var errors = 0
        let monitor = ClipboardMonitor(pasteboard: pasteboard, settingsProvider: { settings },
            onCapture: { captures.append($0) }, onError: { _ in errors += 1 })
        monitor.start()
        defer { monitor.stop() }
        let title = "Y Chromosomes of 40% Chinese Descend from Three Neolithic Super-Grandfathers"
        let translation = "中文可以翻译为《约40%的中国人，其Y染色体源自新石器时代的三位超级祖先》。"
        let text = title + "\n" + translation + "\nPubMed\n+1\n内容比较复杂的. "
        let html = """
            <section><p><a href="https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0105691">\(title)</a></p>
            <p>\(translation)</p><p><picture><img width="32" height="32" alt="image"
            src="https://www.google.com/s2/favicons?domain=https://pubmed.ncbi.nlm.nih.gov&amp;sz=32"></picture>
            <span>PubMed</span><sup>+1</sup></p><p>内容比较复杂的.&nbsp;</p></section>
            """
        pasteboard.declareTypes(browserTypes, owner: nil)
        try require(pasteboard.setString(text, forType: .string))
        try require(pasteboard.setString(html, forType: .html))
        try require(pasteboard.setData(Data([0, 1, 2]), forType: chromiumToken))
        try require(pasteboard.setString("https://example.test/rich-selection", forType: chromiumURL))
        // Exercise the normal timer, not a direct classifier or manual poll.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while captures.isEmpty && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(captures.count == 1 && errors == 0)
        let prepared = captures[0]
        try require(prepared.dataType == (compactMode ? "text" : "html"))
        try await history.insert(prepared: prepared)
        let page = try await history.page(query: "超级祖先")
        try require(page.items.count == 1)
        guard let saved = try await history.event(contentHash: page.items[0].contentHash)
        else { throw Failure.assertion(#line) }
        let savedEvent = try EventCodec.decode(saved.eventData)
        try require(savedEvent.representation(for: EventClassifier.textType)?.data == Data(text.utf8))
        if compactMode {
            try require(prepared.contentHash == EventClassifier.hash(Data(text.utf8)))
            try require(savedEvent.items.flatMap(\.dataList).map(\.type) == [EventClassifier.textType])
            try require(saved.item.display == Data(text.utf8))
        } else {
            try require(savedEvent.representation(for: "public.html")?.data == Data(html.utf8))
            try require(prepared.contentHash == EventClassifier.hash(Data(html.utf8)))
            try require(prepared.compactContentHash == nil && prepared.compactDisplay == nil)
        }
        try await monitor.restore(saved, compactMode: compactMode)
        try require(pasteboard.string(forType: .string) == text)
        try require(pasteboard.data(forType: .html) == (compactMode ? nil : Data(html.utf8)))
        await monitor.pollNow()
        try require(captures.count == 1 && errors == 0)
    }

}
