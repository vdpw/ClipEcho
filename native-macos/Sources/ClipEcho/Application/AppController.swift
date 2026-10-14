import AppKit
import QuartzCore
import ClipEchoCore

@MainActor
final class AppController: NSObject, NSWindowDelegate {
  let history: HistoryService
  private(set) var settings: AppSettings
  private(set) var stats: HistoryStats
  private(set) var storageURL: URL
  private(set) var window: NSWindow?
  let readOnly: Bool
  private var historyView: HistoryViewController!
  private var settingsView: SettingsViewController!
  private var clipboard: ClipboardMonitor!
  private var menuBar: MenuBarController!
  private var settingsVisible = false
  private var refreshTask: Task<Void, Never>?
  let mirror: HistoryMirror?
  private var pendingItems: Set<String> = []
  private var settingsMutationInFlight = false
  private var themePreview: String?
  private let loginItem: any LoginItemManaging
  private let pasteboard: NSPasteboard
  private let autosaveWindowFrame: Bool
  private let qaMode: Bool

  init(
    history: HistoryService, snapshot: HistorySnapshot, readOnly: Bool,
    mirror: HistoryMirror? = nil,
    loginItem: any LoginItemManaging = LoginItemService(), pasteboard: NSPasteboard = .general,
    autosaveWindowFrame: Bool = true, qaMode: Bool = false
  ) {
    self.history = history
    self.mirror = mirror
    self.loginItem = loginItem
    self.pasteboard = pasteboard
    self.autosaveWindowFrame = autosaveWindowFrame
    self.qaMode = qaMode
    self.readOnly = readOnly
    settings = snapshot.settings
    stats = snapshot.stats
    storageURL = snapshot.storageURL
    super.init()
  }

  func start(hidden: Bool) {
    buildWindow()
    menuBar = MenuBarController(controller: self)
    rebuildApplicationMenu()
    applyAppearance()
    menuBar.reload()
    clipboard = ClipboardMonitor(
      pasteboard: pasteboard, settingsProvider: { [weak self] in self?.settings ?? AppSettings() },
      onCapture: { [weak self] event in
        guard let self else { return }
        Task { @MainActor in
          do {
            try await self.history.insert(prepared: event)
            self.menuBar.captureFailed = false
            await self.reloadSnapshot()
            self.scheduleRefresh()
          } catch { self.presentBackgroundError(error) }
        }
      }, onError: { [weak self] error in self?.presentBackgroundError(error) })
    if !readOnly { clipboard.start() }
    if hidden { NSApp.setActivationPolicy(.accessory) } else { showHistory() }
  }

  private func buildWindow() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.title = "ClipEcho"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    let minimumSize = NSSize(width: 600, height: 400)
    let maximumSize = NSSize(width: 1000, height: 900)
    window.contentMinSize = minimumSize
    window.contentMaxSize = maximumSize
    window.collectionBehavior.insert(.fullScreenNone)
    window.isMovableByWindowBackground = false
    window.isReleasedWhenClosed = false
    window.delegate = self
    if autosaveWindowFrame {
      window.setFrameAutosaveName("ClipEchoNativeParityMain")
      if !window.setFrameUsingName("ClipEchoNativeParityMain") { window.center() }
    } else {
      window.center()
    }
    self.window = window
    historyView = HistoryViewController(controller: self)
    settingsView = SettingsViewController(controller: self)
    // AppKit ignores contentMin/MaxSize for Auto Layout content. Bound both
    // pages explicitly, while leaving every size inside this range available.
    for content in [historyView.view, settingsView.view] {
      NSLayoutConstraint.activate([
        content.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumSize.width),
        content.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumSize.height),
        content.widthAnchor.constraint(lessThanOrEqualToConstant: maximumSize.width),
        content.heightAnchor.constraint(lessThanOrEqualToConstant: maximumSize.height),
      ])
    }
    installContent(historyView)
  }

  private func installContent(_ content: NSViewController) {
    guard let window else { return }
    let frame = window.frame
    let size = window.contentView?.bounds.size ?? frame.size
    content.view.frame = NSRect(origin: .zero, size: size)
    window.contentViewController = content
    // Preserve the current frame when attaching a page. A preferredContentSize
    // would create fixed-size constraints that override interactive resizing.
    window.setFrame(frame, display: window.isVisible)
  }

  @objc func showHistory() {
    let resetSession = settingsVisible
    settingsVisible = false
    installContent(historyView)
    if resetSession {
      historyView.resetSession()
      historyView.reload(reset: true)
    } else {
      historyView.reload()
    }
    activateWindow()
  }

  @objc func showSettings() {
    if settingsVisible {
      activateWindow()
      return
    }
    historyView.resetSession()
    settingsView.resetSession()
    settingsVisible = true
    installContent(settingsView)
    settingsView.reload()
    activateWindow()
  }

  @objc func focusSearch() {
    guard NSApp.modalWindow == nil else { return }
    if settingsVisible { showHistory() } else { activateWindow() }
    historyView.focusSearch()
  }

  func activateWindow() {
    NSApp.setActivationPolicy(.regular)
    if window?.isMiniaturized == true { window?.deminiaturize(nil) }
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    sender.orderOut(nil)
    NSApp.setActivationPolicy(.accessory)
    return false
  }

  func stop() {
    refreshTask?.cancel()
    clipboard?.stop()
    menuBar?.stop()
  }

  enum RestoreOutcome { case failed, copied, copiedWithPostProcessingFailure }

  @discardableResult func restore(_ item: HistoryItem) async -> Bool {
    await restoreWithOutcome(item) != .failed
  }

  @discardableResult func restoreFromMenu(_ item: HistoryItem) async -> Bool {
    let result = await restoreWithOutcome(item, reportFailure: false)
    if result != .failed, settings.moveRestoredItemToTop, !settingsVisible {
      historyView.reload(scrollToTop: window?.isKeyWindow != true)
    }
    return result != .failed
  }

  func restoreWithOutcome(_ item: HistoryItem, reportFailure: Bool = true) async -> RestoreOutcome {
    do {
      guard let event = try await history.event(contentHash: item.contentHash) else {
        throw StorageError.invalidEvent
      }
      try await clipboard.restore(event, compactMode: settings.compactMode)
      if settings.moveRestoredItemToTop && !readOnly {
        do {
          try await history.moveToTop(contentHash: item.contentHash)
          await reloadSnapshot()
          menuBar?.reload()
          Task { try? await mirror?.scheduleRefresh() }
        } catch {
          if reportFailure { presentError(error, operation: "restore_post_processing_failed") }
          return .copiedWithPostProcessingFailure
        }
      }
      return .copied
    } catch {
      if reportFailure { presentError(error, operation: "restore_clipboard") }
      return .failed
    }
  }

  func togglePin(_ item: HistoryItem) {
    Task { _ = await togglePinAndWait(item) }
  }

  func delete(_ item: HistoryItem) {
    Task { _ = await deleteAndWait(item) }
  }

  @discardableResult func togglePinAndWait(_ item: HistoryItem) async -> Bool {
    await mutateAndWait(operation: "pin_history", itemKey: item.contentHash) {
      try await self.history.togglePin(item)
    }
  }

  @discardableResult func deleteAndWait(_ item: HistoryItem) async -> Bool {
    await mutateAndWait(operation: "delete_history", itemKey: item.contentHash) {
      try await self.history.delete(item)
    }
  }

  func clearHistory(includePinned: Bool, reportFailure: Bool = true) {
    Task {
      if await clearHistoryAsync(includePinned: includePinned, reportFailure: reportFailure),
        !settingsVisible
      {
        historyView.reload(scrollToTop: window?.isKeyWindow != true)
      }
    }
  }

  @discardableResult func clearHistoryAsync(includePinned: Bool, reportFailure: Bool = true) async
    -> Bool
  {
    await mutateAndWait(operation: "clear_history", reportFailure: reportFailure) {
      try await self.history.clear(includePinned: includePinned)
    }
  }

  func updateSetting(_ key: String, value: String) {
    Task { _ = await updateSettingAsync(key, value: value) }
  }

  @discardableResult func updateSettingAsync(_ key: String, value: String) async -> Bool {
    if key == "theme" { return await persistTheme(value) }
    return await mutateAndWait(operation: "update_settings", settingsMutation: true) {
      try await self.history.setSetting(key: key, value: value)
    }
  }

  /// A theme changes presentation only: avoid history statistics, menu queries,
  /// and export work while the user is choosing an appearance.
  private func persistTheme(_ value: String) async -> Bool {
    guard !settingsMutationInFlight else { return false }
    settingsMutationInFlight = true
    defer { settingsMutationInFlight = false }
    do {
      guard !readOnly else { throw StorageError.readOnly }
      try await history.setSetting(key: "theme", value: value)
      settings = try await history.settings()
      applyAppearance()
      return true
    } catch {
      if let saved = try? await history.settings() { settings = saved }
      applyAppearance()
      presentError(error)
      return false
    }
  }

  /// Keep the newest selection visible while earlier writes finish. Clearing
  /// the preview restores the saved appearance after success or failure.
  func previewTheme(_ theme: String?) {
    themePreview = theme
    applyAppearance()
  }

  func moveStorage(to directory: URL) {
    Task { _ = await moveStorageAsync(to: directory) }
  }

  @discardableResult func moveStorageAsync(to directory: URL) async -> Bool {
    await mutateAndWait(operation: "move_storage", pauseCapture: true, settingsMutation: true) {
      try await self.mirror?.pauseForRelocation(to: directory.appendingPathComponent("clipecho.db"))
      do {
        try await self.history.moveStorage(to: directory)
      } catch {
        let url = try await self.history.snapshot().storageURL
        try? await self.mirror?.resume(databaseURL: url)
        throw error
      }
      let url = try await self.history.snapshot().storageURL
      try await self.mirror?.resume(databaseURL: url)
    }
  }

  var launchAtLoginEnabled: Bool { loginItem.isEnabled }

  @discardableResult func setLaunchAtLogin(_ enabled: Bool) -> Bool {
    guard !readOnly else {
      presentError(StorageError.readOnly)
      return false
    }
    do {
      try loginItem.setEnabled(enabled)
      return true
    } catch {
      presentError(error, operation: "update_autostart")
      return false
    }
  }

  private func mutateAndWait(
    operation: String, pauseCapture: Bool = false, itemKey: String? = nil,
    settingsMutation: Bool = false, reportFailure: Bool = true,
    _ work: @escaping @MainActor () async throws -> Void
  ) async -> Bool {
    if let itemKey { guard pendingItems.insert(itemKey).inserted else { return false } }
    if settingsMutation {
      guard !settingsMutationInFlight else { return false }
      settingsMutationInFlight = true
    }
    if pauseCapture { clipboard.stop() }
    defer {
      if pauseCapture && !readOnly { clipboard.start() }
      if let itemKey { pendingItems.remove(itemKey) }
      if settingsMutation { settingsMutationInFlight = false }
    }
    do {
      guard !readOnly else { throw StorageError.readOnly }
      try await work()
      await reloadSnapshot()
      applyAppearance()
      if settingsMutation { rebuildApplicationMenu() }
      menuBar?.reload()
      Task { try? await mirror?.scheduleRefresh() }
      return true
    } catch {
      await reloadSnapshot()
      if reportFailure { presentError(error, operation: operation) }
      return false
    }
  }

  private func reloadSnapshot() async {
    do {
      let snapshot = try await history.snapshot()
      settings = snapshot.settings
      stats = snapshot.stats
      storageURL = snapshot.storageURL
    } catch { presentBackgroundError(error) }
  }

  private func scheduleRefresh() {
    Task { try? await mirror?.scheduleRefresh() }
    refreshTask?.cancel()
    refreshTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(120))
      guard !Task.isCancelled else { return }
      self?.refresh(clipboardUpdate: true)
    }
  }

  private func refresh(clipboardUpdate: Bool = false) {
    Task { try? await mirror?.scheduleRefresh() }
    if settingsVisible {
      // The original settings page does not subscribe to clipboard updates.
      // Keep an active form and its keyboard focus intact during capture.
      if !clipboardUpdate { settingsView.reload() }
    } else {
      historyView.reload(scrollToTop: clipboardUpdate && window?.isKeyWindow != true)
    }
    menuBar?.reload()
  }

  private func applyAppearance() {
    let appearance: NSAppearance?
    switch themePreview ?? settings.theme {
    case "light": appearance = NSAppearance(named: .aqua)
    case "dark": appearance = NSAppearance(named: .darkAqua)
    default: appearance = nil
    }
    guard NSApp.appearance?.name != appearance?.name || window?.appearance != nil else { return }
    // All windows inherit the app appearance. A second explicit window theme
    // causes another appearance invalidation and prevents System inheritance.
    // Commit the visible frame during the click, including menu tracking mode.
    NSAnimationContext.beginGrouping()
    NSAnimationContext.current.duration = 0
    NSAnimationContext.current.allowsImplicitAnimation = false
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    window?.appearance = nil
    NSApp.appearance = appearance
    window?.contentView?.layoutSubtreeIfNeeded()
    window?.displayIfNeeded()
    CATransaction.commit()
    NSAnimationContext.endGrouping()
  }

  func t(_ key: String) -> String { L10n.string(key, language: settings.language) }

  func confirm(
    title: String, message: String, confirmLabel: String? = nil, destructive: Bool = true
  ) -> Bool {
    guard let window else { return false }
    let warning = t("cannotUndo")
    let text = destructive && !message.contains(warning) ? message + "\n\n" + warning : message
    return ConfirmationOverlay.run(
      in: window, title: title, message: text, warningText: destructive ? warning : nil,
      cancelLabel: t("cancel"), confirmLabel: confirmLabel ?? t("delete"), destructive: destructive)
  }

  func presentError(_ error: Error, operation: String = "update_settings") {
    // Never expose arbitrary framework, filesystem, database, or clipboard messages.
    let key: String
    if (error as? StorageError) == .readOnly {
      key = "readOnly"
    } else if operation == "move_storage", let failure = error as? StorageError {
      switch failure {
      case .destinationExists: key = "error.storage_destination_exists"
      case .inaccessible: key = "error.storage_permission_denied"
      case .unsafePath, .invalidConfiguration: key = "error.storage_invalid_directory"
      default: key = "error.move_storage"
      }
    } else {
      key = "error.\(operation)"
    }
    let message = t(key)
    if settingsVisible { settingsView.showError(message) } else { historyView.showError(message) }
  }

  private func presentBackgroundError(_ error: Error) {
    // Resource rejection is the original dismissible history notice. Other
    // asynchronous capture failures remain quiet in the production UI.
    if let failure = error as? ClipboardMonitor.Failure, case .tooLarge = failure, !settingsVisible
    {
      historyView.showCaptureNotice(t("captureRejected"))
    }
  }

  func flushMirrorForTermination() async {
    guard let mirror else { return }
    _ = try? await history.snapshot()  // Barrier behind every queued store mutation.
    _ = try? await mirror.scheduleRefresh()
    try? await mirror.shutdown()
  }

  private func rebuildApplicationMenu() {
    let main = NSMenu()
    let appItem = NSMenuItem()
    let app = NSMenu(title: "ClipEcho")
    app.addItem(
      withTitle: t("about"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      keyEquivalent: "")
    app.addItem(.separator())
    let settingsItem = app.addItem(
      withTitle: t("settingsEllipsis"), action: #selector(showSettings), keyEquivalent: ",")
    settingsItem.target = self
    app.addItem(.separator())
    let services = NSMenu(title: t("services"))
    let serviceItem = NSMenuItem(title: t("services"), action: nil, keyEquivalent: "")
    serviceItem.submenu = services
    app.addItem(serviceItem)
    NSApp.servicesMenu = services
    app.addItem(.separator())
    app.addItem(withTitle: t("hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    let hideOthers = app.addItem(
      withTitle: t("hideOthers"), action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: "h")
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    app.addItem(.separator())
    app.addItem(
      withTitle: t("quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = app
    main.addItem(appItem)
    let fileItem = NSMenuItem()
    let file = NSMenu(title: t("file"))
    file.addItem(
      withTitle: t("closeWindow"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    fileItem.submenu = file
    main.addItem(fileItem)
    let editItem = NSMenuItem()
    let edit = NSMenu(title: t("edit"))
    edit.addItem(withTitle: t("undo"), action: Selector(("undo:")), keyEquivalent: "z")
    let redo = edit.addItem(withTitle: t("redo"), action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    edit.addItem(.separator())
    for (key, action, shortcut) in [
      ("cut", #selector(NSText.cut(_:)), "x"), ("copy", #selector(NSText.copy(_:)), "c"),
      ("paste", #selector(NSText.paste(_:)), "v"),
      ("selectAll", #selector(NSText.selectAll(_:)), "a"),
    ] {
      edit.addItem(withTitle: t(key), action: action, keyEquivalent: shortcut)
    }
    let search = edit.addItem(
      withTitle: t("search"), action: #selector(focusSearch), keyEquivalent: "f")
    search.target = self
    search.isHidden = true
    search.allowsKeyEquivalentWhenHidden = true
    editItem.submenu = edit
    main.addItem(editItem)
    let viewItem = NSMenuItem()
    let viewMenu = NSMenu(title: t("view"))
    let fullscreen = viewMenu.addItem(
      withTitle: t("enterFullScreen"), action: #selector(NSWindow.toggleFullScreen(_:)),
      keyEquivalent: "f")
    fullscreen.keyEquivalentModifierMask = [.command, .control]
    if qaMode {
      let qaMenu = viewMenu.addItem(
        withTitle: "QA：菜单栏", action: nil, keyEquivalent: "")
      qaMenu.submenu = menuBar.menuForQA
    }
    viewItem.submenu = viewMenu
    main.addItem(viewItem)
    let windowItem = NSMenuItem()
    let windowMenu = NSMenu(title: t("window"))
    windowMenu.addItem(
      withTitle: t("minimize"), action: #selector(NSWindow.performMiniaturize(_:)),
      keyEquivalent: "m")
    windowMenu.addItem(
      withTitle: t("zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    windowMenu.addItem(.separator())
    windowMenu.addItem(
      withTitle: t("closeWindow"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    windowItem.submenu = windowMenu
    main.addItem(windowItem)
    NSApp.windowsMenu = windowMenu
    let helpItem = NSMenuItem()
    let helpMenu = NSMenu(title: t("help"))
    helpItem.submenu = helpMenu
    main.addItem(helpItem)
    NSApp.helpMenu = helpMenu
    NSApp.mainMenu = main
  }
}
