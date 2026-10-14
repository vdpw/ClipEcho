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

  private static func descendants(of view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { descendants(of: $0) }
  }

  private static func report(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
  }

  // AppKit needs a delegate during window/appearance transitions. Without one,
  // a command-line self-test can terminate successfully before its final checks.
  private final class LifecycleDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
      return .terminateCancel
    }
  }

  static func run() async throws {
    let appDelegate = LifecycleDelegate()
    NSApplication.shared.delegate = appDelegate
    defer {
      NSApplication.shared.delegate = nil
      withExtendedLifetime(appDelegate) {}
    }
    report("Native self-test started")
    try TrayParitySelfTest.run()
    try TrayParitySelfTest.runTrackingDelivery()
    try await ClipboardCaptureSelfTest.run()
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
    report("Native self-test capture passed")
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
    try require(window.contentMaxSize == NSSize(width: 1000, height: 900))
    try require(window.collectionBehavior.contains(.fullScreenNone))
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

    // Interactive resize used to be undone by a later layout even though the
    // window's resizable style and min/max size properties looked correct.
    func settleWindowSize(_ expected: NSSize) async throws {
      window.contentView?.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(30))
      window.contentView?.layoutSubtreeIfNeeded()
      try require(window.contentView?.bounds.size == expected)
      try require(window.contentViewController?.view.bounds.size == expected)
    }
    let expandedSize = NSSize(width: 1000, height: 900)
    window.setContentSize(expandedSize)
    try await settleWindowSize(expandedSize)
    let navigationSize = NSSize(width: 980, height: 560)
    window.setContentSize(navigationSize)
    try await settleWindowSize(navigationSize)
    controller.showSettings()
    try await settleWindowSize(navigationSize)
    controller.showHistory()
    try await settleWindowSize(navigationSize)
    let minimumSize = NSSize(width: 600, height: 400)
    window.setContentSize(minimumSize)
    try await settleWindowSize(minimumSize)
    controller.showSettings()
    try await settleWindowSize(minimumSize)
    window.setContentSize(expandedSize)
    try await settleWindowSize(expandedSize)
    controller.showHistory()
    try await settleWindowSize(expandedSize)
    // Out-of-range requests must also settle at the explicit bounds on both
    // pages, rather than relying on min/max properties ignored by Auto Layout.
    for showPage in [controller.showHistory, controller.showSettings] {
      showPage()
      window.setContentSize(NSSize(width: 1200, height: 1100))
      try await settleWindowSize(expandedSize)
      window.setContentSize(NSSize(width: 500, height: 300))
      try await settleWindowSize(minimumSize)
    }
    controller.showHistory()
    window.setContentSize(historySize ?? NSSize(width: 600, height: 700))
    try await settleWindowSize(NSSize(width: 600, height: 700))
    report("Native self-test window resize passed: 600x400...1000x900 bounds, expand, shrink and navigation")
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
    report("Native self-test initial UI passed")
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
    report("Native self-test coordinator passed")
    try require(await writable.updateSettingAsync("theme", value: "light"))
    writable.showSettings()
    guard let settingsView = writable.window?.contentViewController as? SettingsViewController,
      let appearanceCategory = descendants(of: settingsView.view).compactMap({ $0 as? SettingsCategoryButton })
        .first(where: { $0.title == writable.t("appearanceSettings") })
    else { throw Failure.assertion(#line) }
    appearanceCategory.performClick(nil)
    let choices = descendants(of: settingsView.view).compactMap { $0 as? SettingsThemeButton }
    guard let light = choices.first(where: { $0.theme == "light" }),
      let dark = choices.first(where: { $0.theme == "dark" }),
      let system = choices.first(where: { $0.theme == "system" })
    else { throw Failure.assertion(#line) }
    dark.performClick(nil)
    try require(writable.window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua && dark.chosen)
    await Task.yield()
    light.performClick(nil)
    try require(writable.window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua && light.chosen)
    system.performClick(nil)
    try require(writable.window?.appearance == nil && NSApp.appearance == nil && system.chosen)
    for _ in 0..<100 {
      if (try await writableHistory.settings()).theme == "system" { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    try require((try await writableHistory.settings()).theme == "system")
    await settingsView.diagnosticWaitForThemeSave()
    try require(writable.settings.theme == "system" && system.chosen && system.state == .on)
    let retainedChoices = descendants(of: settingsView.view).compactMap { $0 as? SettingsThemeButton }
    try require(choices.count == 3 && zip(choices, retainedChoices).allSatisfy { $0 === $1 })
    try require(writable.window?.appearance == nil && NSApp.appearance == nil)

    // The menu count uses the same accessible circle-question help as other settings.
    guard let menuCategory = descendants(of: settingsView.view).compactMap({ $0 as? SettingsCategoryButton })
      .first(where: { $0.title == writable.t("menuBarSettings") })
    else { throw Failure.assertion(#line) }
    menuCategory.performClick(nil)
    let helpLabel = L10n.format("settingHelp", language: "zh-CN", args: [writable.t("menuBarItemLimit")])
    guard let help = descendants(of: settingsView.view).compactMap({ $0 as? SettingsButton })
      .first(where: { $0.accessibilityLabel() == helpLabel })
    else { throw Failure.assertion(#line) }
    try require(help.symbol == "questionmark.circle")
    help.performClick(nil)
    try require(help.expanded)
    try require(descendants(of: settingsView.view).contains { $0 is SettingsHelpBubble })
    help.performClick(nil)
    try require(!help.expanded)

    report("Native self-test theme controls passed")
    let htmlEvent = ClipboardEvent(items: [ClipboardItem(dataList: [
      ClipboardRepresentation(type: "public.html", data: Data("<span>Hello <b>native</b></span>".utf8)),
      ClipboardRepresentation(type: EventClassifier.textType, data: Data("Hello native".utf8)),
    ])])
    guard let preparedHTML = EventClassifier.prepare(event: htmlEvent, compactMode: false)
    else { throw Failure.assertion(#line) }
    try await writableHistory.insert(prepared: preparedHTML)
    guard let storedHTML = try await writableHistory.event(contentHash: preparedHTML.contentHash)
    else { throw Failure.assertion(#line) }
    let htmlCard = HistoryCardView(item: storedHTML.item, language: "zh-CN", query: "")
    htmlCard.expanded = true
    htmlCard.detailState = 1
    htmlCard.refresh()
    let loadingHeight = htmlCard.desiredHeight(width: 560)
    htmlCard.detail = try InlineHistoryDetail.build(storedHTML)
    htmlCard.detailState = 3
    htmlCard.refresh()
    try require(!htmlCard.diagnosticPreviewIsReady)
    try require(htmlCard.desiredHeight(width: 560) == loadingHeight)
    let renderedHTML = try await htmlCard.diagnosticHTMLSnapshot()
    try require(renderedHTML?.height == 104 && htmlCard.diagnosticPreviewIsReady)
    let renderedHeight = htmlCard.desiredHeight(width: 560)
    let previewIdentity = htmlCard.diagnosticPreviewIdentity
    htmlCard.expanded = false
    htmlCard.refresh()
    htmlCard.expanded = true
    htmlCard.refresh()
    try require(previewIdentity != nil && htmlCard.diagnosticPreviewIdentity == previewIdentity)
    try require(htmlCard.desiredHeight(width: 560) == renderedHeight)

    writable.showHistory()
    guard let historyView = writable.window?.contentViewController as? HistoryViewController
    else { throw Failure.assertion(#line) }
    for _ in 0..<100 {
      if historyView.diagnosticCardIdentity(contentHash: preparedHTML.contentHash) != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    guard let displayedHTML = descendants(of: historyView.view).compactMap({ $0 as? HistoryCardView })
      .first(where: { $0.item.contentHash == preparedHTML.contentHash })
    else { throw Failure.assertion(#line) }
    displayedHTML.onToggle?()
    for _ in 0..<100 {
      if displayedHTML.diagnosticPreviewIdentity != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    try require(try await displayedHTML.diagnosticHTMLSnapshot()?.height == 104)
    let displayedPreviewIdentity = displayedHTML.diagnosticPreviewIdentity
    let displayedCardIdentity = historyView.diagnosticCardIdentity(contentHash: preparedHTML.contentHash)
    historyView.reload()
    try await Task.sleep(for: .milliseconds(100))
    try require(historyView.diagnosticCardIdentity(contentHash: preparedHTML.contentHash) == displayedCardIdentity)
    try require(displayedHTML.diagnosticPreviewIdentity == displayedPreviewIdentity)
    displayedHTML.diagnosticSimulateHTMLProcessTermination()
    try require(displayedHTML.detailState == 2 && displayedHTML.diagnosticRetryIsVisible)
    try require(!displayedHTML.diagnosticPreviewIsReady)
    historyView.reload()
    try await Task.sleep(for: .milliseconds(100))
    try require(displayedHTML.detailState == 2 && displayedHTML.diagnosticRetryIsVisible)
    displayedHTML.onRetry?()
    try require(displayedHTML.diagnosticPreviewIdentity == nil && displayedHTML.detailState == 1)
    for _ in 0..<100 {
      if displayedHTML.diagnosticPreviewIdentity != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    try require(try await displayedHTML.diagnosticHTMLSnapshot()?.height == 104)
    try require(displayedHTML.diagnosticPreviewIsReady && !displayedHTML.diagnosticRetryIsVisible)
    report("Native self-test HTML retry passed")
    writable.showSettings()
    guard let benchmarkSettings = writable.window?.contentViewController as? SettingsViewController,
      let benchmarkAppearance = descendants(of: benchmarkSettings.view)
        .compactMap({ $0 as? SettingsCategoryButton })
        .first(where: { $0.title == writable.t("appearanceSettings") }),
      let benchmarkWindow = writable.window
    else { throw Failure.assertion(#line) }
    benchmarkAppearance.performClick(nil)
    benchmarkSettings.view.layoutSubtreeIfNeeded()
    benchmarkWindow.displayIfNeeded()
    var applySamples: [Double] = []
    var layoutSamples: [Double] = []
    var displaySamples: [Double] = []
    for index in 0..<16 {
      try await Task.sleep(for: .milliseconds(25))
      let started = ProcessInfo.processInfo.systemUptime
      writable.previewTheme(index.isMultiple(of: 2) ? "dark" : "light")
      let applied = ProcessInfo.processInfo.systemUptime
      benchmarkSettings.view.layoutSubtreeIfNeeded()
      let laidOut = ProcessInfo.processInfo.systemUptime
      benchmarkWindow.displayIfNeeded()
      let displayed = ProcessInfo.processInfo.systemUptime
      applySamples.append((applied - started) * 1000)
      layoutSamples.append((laidOut - applied) * 1000)
      displaySamples.append((displayed - laidOut) * 1000)
    }
    for (name, values) in [("apply", applySamples), ("layout", layoutSamples), ("display", displaySamples)] {
      report("Theme benchmark \(name): mean=\(values.reduce(0, +) / Double(values.count)) ms max=\(values.max() ?? 0) ms")
    }
    writable.previewTheme(nil)
    let benchmarkChoices = descendants(of: benchmarkSettings.view).compactMap { $0 as? SettingsThemeButton }
    for theme in ["dark", "light", "dark", "light"] {
      guard let button = benchmarkChoices.first(where: { $0.theme == theme })
      else { throw Failure.assertion(#line) }
      let started = ProcessInfo.processInfo.systemUptime
      try require(button.accessibilityPerformPress())
      benchmarkWindow.displayIfNeeded()
      report("Theme benchmark accessible press: \((ProcessInfo.processInfo.systemUptime - started) * 1000) ms")
      try await Task.sleep(for: .milliseconds(25))
    }
    await benchmarkSettings.diagnosticWaitForThemeSave()
    var mousePresses = 0
    for button in benchmarkChoices {
      guard let reset = benchmarkChoices.first(where: { $0 !== button })
      else { throw Failure.assertion(#line) }
      for x: CGFloat in [4, 17, 34, 51, 64] {
        for y: CGFloat in [4, 12, 23, 32, 45, 58, 64] {
          try require(reset.accessibilityPerformPress())
          let location = button.convert(NSPoint(x: x, y: y), to: nil)
          guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location,
            modifierFlags: [], timestamp: 0, windowNumber: benchmarkWindow.windowNumber,
            context: nil, eventNumber: mousePresses, clickCount: 1, pressure: 1)
          else { throw Failure.assertion(#line) }
          button.mouseDown(with: down)
          try require(button.chosen && button.state == .on)
          try require(benchmarkChoices.filter(\.chosen).count == 1)
          mousePresses += 1
        }
      }
    }
    await benchmarkSettings.diagnosticWaitForThemeSave()
    try require(mousePresses == 105)
    try require((try await writableHistory.settings()).theme == benchmarkChoices.last?.theme)
    report("Theme mouseDown grid passed: 105/105 thumbnail and label positions")
    guard let systemChoice = benchmarkChoices.first(where: { $0.theme == "system" }),
      let lightChoice = benchmarkChoices.first(where: { $0.theme == "light" }),
      let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: benchmarkWindow.windowNumber, context: nil,
        characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)
    else { throw Failure.assertion(#line) }
    try require(lightChoice.accessibilityPerformPress())
    systemChoice.keyDown(with: space)
    try require(systemChoice.chosen && NSApp.appearance == nil)
    await benchmarkSettings.diagnosticWaitForThemeSave()
    try require((try await writableHistory.settings()).theme == "system")
    for language in ["zh-CN", "zh-TW", "en"] {
      try require(await writable.updateSettingAsync("language", value: language))
      benchmarkSettings.reload()
      guard let clipboardCategory = descendants(of: benchmarkSettings.view)
        .compactMap({ $0 as? SettingsCategoryButton })
        .first(where: { $0.title == writable.t("clipboardSettings") })
      else { throw Failure.assertion(#line) }
      clipboardCategory.performClick(nil)
      for width: CGFloat in [600, 820] {
        benchmarkWindow.setContentSize(NSSize(width: width, height: 700))
        benchmarkSettings.view.layoutSubtreeIfNeeded()
        guard let clear = descendants(of: benchmarkSettings.view)
          .compactMap({ $0 as? SettingsButton }).first(where: { $0.identifier?.rawValue == "clear" }),
          let row = clear.superview as? NSStackView,
          let description = descendants(of: row).compactMap({ $0 as? SettingsWrappingLabel })
            .first(where: { $0.stringValue == L10n.format("clearHistoryDescription", language: language,
              args: [String(writable.stats.totalItems)]) }),
          let textCell = description.cell
        else { throw Failure.assertion(#line) }
        let textFrame = row.convert(description.bounds, from: description)
        let measured = textCell.cellSize(forBounds: NSRect(x: 0, y: 0,
          width: description.bounds.width, height: .greatestFiniteMagnitude)).height
        try require(textFrame.minY >= 9.5 && textFrame.maxY <= row.bounds.height - 9.5)
        try require(description.bounds.height >= ceil(measured) - 0.5)
      }
    }
    report(
      "Native self-test passed: delayed browser capture, capture, privacy, restore/echo, pin/clear/delete, awaited settings, rapid theme persistence/control reuse, menu count help, multilingual settings wrapping/padding, restore-order rules, window resize/navigation/lifecycle, WebKit HTML filtering/CSP/heights, stable HTML expansion/card reuse/failure retry and measured tray presentation. Isolated database and named pasteboard."
    )
  }
}
