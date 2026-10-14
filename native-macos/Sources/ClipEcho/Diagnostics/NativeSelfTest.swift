import AppKit
import ClipEchoCore

/// Exercises actual AppKit pasteboard APIs against a named pasteboard and a private fixture.
/// The user's general clipboard and production database are never touched.
@MainActor
enum NativeSelfTest {
  enum Failure: Error { case assertion(Int) }
  static func require(_ condition: Bool, line: Int = #line) throws {
    if !condition { throw Failure.assertion(line) }
  }

  static func run() async throws {
    try TrayParitySelfTest.run()
    try TrayParitySelfTest.runTrackingDelivery()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "clipecho-native-qa-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SQLiteStore(url: root.appendingPathComponent("clipecho.db"))
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    var captured = 0
    var captureError = false
    let monitor = ClipboardMonitor(
      pasteboard: pasteboard, settingsProvider: { (try? store.settings()) ?? AppSettings() },
      onCapture: { prepared in
        do {
          try store.insert(prepared: prepared)
          captured += 1
        } catch { captureError = true }
      }, onError: { _ in captureError = true })
    monitor.start()
    defer { monitor.stop() }
    pasteboard.clearContents()
    pasteboard.setString("Native synthetic fixture\n第二行", forType: .string)
    await monitor.pollNow()
    try require(captured == 1 && !captureError)
    let page = try store.page()
    try require(page.items.count == 1)
    let item = page.items[0]
    try store.setPinned(contentHash: item.contentHash, pinned: true)
    try store.clear(includePinned: false)
    try require(try store.stats().totalItems == 1)
    guard let saved = try store.event(contentHash: item.contentHash) else {
      throw Failure.assertion(#line)
    }
    try await monitor.restore(saved, compactMode: false)
    await monitor.pollNow()
    try require(captured == 1)
    try require(pasteboard.string(forType: .string) == "Native synthetic fixture\n第二行")
    try require(
      pasteboard.data(forType: NSPasteboard.PasteboardType(PasteboardProtocol.sourceType)) == Data()
    )
    let privateItem = NSPasteboardItem()
    privateItem.setString("Never persist this synthetic value", forType: .string)
    privateItem.setData(
      Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    pasteboard.clearContents()
    pasteboard.writeObjects([privateItem])
    await monitor.pollNow()
    try require(captured == 1)
    pasteboard.clearContents()
    pasteboard.setString("Next foreign copy", forType: .string)
    await monitor.pollNow()
    try require(captured == 2 && !captureError)
    let app = NSApplication.shared
    let history = HistoryService(
      storage: try SQLiteStore(url: root.appendingPathComponent("clipecho.db"), readOnly: true))
    let controller = AppController(
      history: history, snapshot: try await history.snapshot(), readOnly: true,
      pasteboard: pasteboard, autosaveWindowFrame: false)
    controller.start(hidden: true)
    try require(app.activationPolicy() == .accessory)
    controller.showHistory()
    try require(controller.window?.isVisible == true && app.activationPolicy() == .regular)
    let historySize = controller.window?.contentView?.bounds.size
    try require(historySize == NSSize(width: 600, height: 700))
    controller.showSettings()
    try require(controller.window?.contentViewController is SettingsViewController)
    try require(controller.window?.contentView?.bounds.size == historySize)
    guard let window = controller.window else { throw Failure.assertion(#line) }
    try require(window.styleMask.contains(.fullSizeContentView))
    try require(window.titleVisibility == .hidden && window.titlebarAppearsTransparent)
    try require(window.contentMinSize == NSSize(width: 600, height: 400))
    controller.focusSearch()
    try await Task.sleep(for: .milliseconds(20))
    try require(window.contentViewController is HistoryViewController)
    try require((window.firstResponder as? NSTextView)?.isFieldEditor == true)
    controller.showSettings()
    try require(!controller.windowShouldClose(window))
    try require(!window.isVisible && app.activationPolicy() == .accessory)
    controller.showHistory()
    try require(window.isVisible && app.activationPolicy() == .regular)
    try require(window.contentView?.bounds.size == historySize)
    let html = HistoryHTMLPreviewView(
      html:
        "<h1>Title</h1><p><b>A &amp; B</b></p><script>hidden</script><img src='https://example.test/image'/><a href='https://example.test' onclick='bad()'>link</a>",
      title: "Synthetic HTML")
    html.frame = NSRect(x: 0, y: 0, width: 440, height: 280)
    let htmlSnapshot = try await html.diagnosticSnapshot()
    try require(
      htmlSnapshot.text.contains("Title") && htmlSnapshot.text.contains("A & B")
        && htmlSnapshot.text.contains("link"))
    try require(!htmlSnapshot.text.contains("hidden"))
    try require(htmlSnapshot.unsafeElementCount == 0 && htmlSnapshot.unsafeAttributeCount == 0)
    try require(htmlSnapshot.fontFamily.contains("PingFang"))
    try require(
      htmlSnapshot.csp.contains("default-src 'none'")
        && htmlSnapshot.csp.contains("style-src 'sha256-")
        && htmlSnapshot.csp.contains("img-src 'none'"))
    try require(htmlSnapshot.height == 280)
    let inlineHTML = HistoryHTMLPreviewView(
      html: "<span>Hello <b>native</b></span>", title: "Synthetic inline HTML")
    let inlineSnapshot = try await inlineHTML.diagnosticSnapshot()
    try require(inlineSnapshot.text.contains("Hello native") && inlineSnapshot.height == 104)
    try require(inlineSnapshot.fontFamily.contains("PingFang"))
    controller.stop()
    window.orderOut(nil)

    // Exercise the same awaited coordinator actions as card buttons, using
    // the fixture and named pasteboard rather than the user's clipboard.
    monitor.stop()
    let writableHistory = HistoryService(
      storage: try SQLiteStore(url: root.appendingPathComponent("clipecho.db")))
    let writable = AppController(
      history: writableHistory, snapshot: try await writableHistory.snapshot(), readOnly: false,
      pasteboard: pasteboard, autosaveWindowFrame: false)
    writable.start(hidden: true)
    defer {
      writable.stop()
      writable.window?.orderOut(nil)
    }
    try require(await writable.updateSettingAsync("move_restored_item_to_top", value: "false"))
    let beforeRestore = try await writableHistory.page()
    guard let foreign = beforeRestore.items.first(where: { !$0.isPinned }) else {
      throw Failure.assertion(#line)
    }
    try require(await writable.restore(foreign))
    let unchanged = try await writableHistory.page()
    try require(
      unchanged.items.first(where: { $0.contentHash == foreign.contentHash })?.timestamp
        == foreign.timestamp)
    try require(await writable.updateSettingAsync("move_restored_item_to_top", value: "true"))
    try require(await writable.restore(foreign))
    let moved = try await writableHistory.page()
    try require(
      (moved.items.first(where: { $0.contentHash == foreign.contentHash })?.timestamp ?? 0)
        > foreign.timestamp)
    try require(pasteboard.string(forType: .string) == "Next foreign copy")
    try require(await writable.togglePinAndWait(foreign))
    try require((try await writableHistory.page()).items.allSatisfy(\.isPinned))
    try require(await writable.clearHistoryAsync(includePinned: false))
    try require((try await writableHistory.stats()).totalItems == 2)
    guard
      let pinnedForeign = (try await writableHistory.page()).items.first(where: {
        $0.contentHash == foreign.contentHash
      })
    else { throw Failure.assertion(#line) }
    try require(await writable.deleteAndWait(pinnedForeign))
    try require((try await writableHistory.stats()).totalItems == 1)
    try require(await writable.updateSettingAsync("language", value: "zh-CN"))
    try require(writable.settings.language == "zh-CN")
    print(
      "Native self-test passed: capture, privacy, restore/echo, pin/clear/delete, awaited settings, restore-order rules, window size/navigation/lifecycle, WebKit HTML filtering/CSP/heights and tray presentation. Isolated database and named pasteboard."
    )
  }
}
