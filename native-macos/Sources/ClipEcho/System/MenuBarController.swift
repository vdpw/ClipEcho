import AppKit
import ClipEchoCore

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
  private unowned let controller: AppController
  private var status: NSStatusItem?
  private let menu = NSMenu()
  private var tracking = false
  private var pendingReload = false
  private var rows: [String: HistoryItem] = [:]
  private var preview: NSPanel?
  private var previewTextView: NSTextView?
  private var reloadTask: Task<Void, Never>?
  private var hoverTask: Task<Void, Never>?
  private var hoverRequest: UUID?
  private var highlightedHash: String?
  private var snapshot: [HistoryItem] = []
  // Production runtime diagnostics do not change the original menu layout.
  var captureFailed = false

  init(controller: AppController) {
    self.controller = controller
    super.init()
    menu.autoenablesItems = false
    menu.delegate = self
  }
  private func t(_ key: String) -> String {
    TrayPresentation.string(key, language: controller.settings.language)
  }

  func reload() {
    if tracking {
      pendingReload = true
      return
    }
    if !controller.settings.showInMenuBar {
      stop()
      return
    }
    if status == nil {
      status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
      status?.button?.image = trayIcon()
      status?.button?.image?.isTemplate = true
      status?.button?.toolTip = "ClipEcho"
      status?.menu = menu
    }
    render(snapshot)
    reloadTask?.cancel()
    reloadTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let items = try await controller.history.trayItems(
          limit: controller.settings.menuBarItemLimit)
        guard !Task.isCancelled else { return }
        snapshot = items
        if tracking { pendingReload = true } else { render(items) }
      } catch { captureFailed = true }
    }
  }

  private func trayIcon() -> NSImage? {
    if let url = Bundle.main.url(forResource: "tray-template", withExtension: "png"),
      let image = NSImage(contentsOf: url)
    {
      image.size = NSSize(width: 18, height: 18)
      return image
    }
    var repository = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    if let image = NSImage(
      contentsOf: repository.appendingPathComponent("src-tauri/icons/tray-template.png"))
    {
      image.size = NSSize(width: 18, height: 18)
      return image
    }
    return NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "ClipEcho")
  }

  private func render(_ items: [HistoryItem]) {
    menu.removeAllItems()
    rows.removeAll()
    add(t("search"), action: #selector(searchHistory))
    menu.addItem(.separator())
    if items.isEmpty {
      heading(t("empty"))
    } else {
      for (index, item) in items.enumerated() {
        if index == 0 || items[index - 1].isPinned != item.isPinned {
          if index > 0 { menu.addItem(.separator()) }
          heading(t(item.isPinned ? "pinned" : "recent"))
        }
        rows[item.contentHash] = item
        let entry = NSMenuItem(
          title: TrayPresentation.label(item, language: controller.settings.language),
          action: #selector(restore(_:)), keyEquivalent: "")
        entry.target = self
        entry.representedObject = item.contentHash
        menu.addItem(entry)
      }
    }
    menu.addItem(.separator())
    add(t("history"), action: #selector(showHistory))
    add(t("settings"), action: #selector(showSettings))
    let clear = add(t("clear"), action: #selector(clearHistory))
    clear.isEnabled = !items.isEmpty && !controller.readOnly
    menu.addItem(.separator())
    add(t("quit"), action: #selector(quit))
  }
  private func heading(_ title: String) {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    menu.addItem(item)
  }
  @discardableResult private func add(_ title: String, action: Selector) -> NSMenuItem {
    let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
    item.target = self
    return item
  }
  func stop() {
    reloadTask?.cancel()
    hoverTask?.cancel()
    hoverRequest = nil
    preview?.orderOut(nil)
    highlightedHash = nil
    if let status { NSStatusBar.system.removeStatusItem(status) }
    status = nil
  }
  @objc private func showHistory() { controller.showHistory() }
  /// QA exposes the same status menu as an accessible application submenu.
  var menuForQA: NSMenu {
    if let parent = menu.supermenu,
      let entry = parent.items.first(where: { $0.submenu === menu })
    {
      entry.submenu = nil
    }
    return menu
  }
  @objc private func searchHistory() { controller.focusSearch() }
  @objc private func showSettings() { controller.showSettings() }
  @objc private func clearHistory() {
    controller.clearHistory(includePinned: false, reportFailure: false)
  }
  @objc private func quit() { NSApp.terminate(nil) }
  @objc private func restore(_ sender: NSMenuItem) {
    if let hash = sender.representedObject as? String, let item = rows[hash] {
      Task { await controller.restoreFromMenu(item) }
    }
  }
  func menuWillOpen(_ menu: NSMenu) { tracking = true }
  func menuDidClose(_ menu: NSMenu) {
    tracking = false
    highlightedHash = nil
    hoverTask?.cancel()
    hoverRequest = nil
    preview?.orderOut(nil)
    if pendingReload {
      pendingReload = false
      reload()
    }
  }

  func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
    let hash = item?.representedObject as? String
    if hash == highlightedHash { return }
    preview?.orderOut(nil)
    hoverTask?.cancel()
    hoverRequest = nil
    highlightedHash = hash
    guard let item, let hash, let row = rows[hash], ["text", "html", "rtf"].contains(row.dataType)
    else { return }
    let request = UUID()
    hoverRequest = request
    let history = controller.history
    let title = item.title
    let pinned = row.isPinned
    hoverTask = Task.detached(priority: .userInitiated) { [weak self] in
      guard !Task.isCancelled else { return }
      guard let preview = try? await history.trayPreviewDetails(contentHash: hash),
        let text = TrayPresentation.previewText(preview), !Task.isCancelled,
        TrayPresentation.needsPreview(title: title, text: text, pinned: pinned)
      else { return }
      // NSMenu tracks in its own run-loop mode. Deliver independently of the
      // main dispatch queue so database completion can show a preview while
      // the menu stays open. Menu objects remain confined to the main actor.
      MenuTrackingDelivery.post { [weak self] in
        guard let self, self.hoverRequest == request,
          self.highlightedHash == hash, self.tracking,
          let entry = self.menu.items.first(where: { $0.representedObject as? String == hash })
        else { return }
        self.showPreview(text, menu: self.menu, item: entry)
      }
    }
  }

  private func showPreview(_ text: String, menu: NSMenu, item: NSMenuItem) {
    let mouse = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
    else { return }
    let visible = screen.visibleFrame
    var itemFrame = item.accessibilityFrame()
    if itemFrame.width <= 0 || itemFrame.height <= 0 || !itemFrame.intersects(visible) {
      let width = max(menu.size.width, 200)
      let statusFrame =
        status?.button?.window?.frame ?? NSRect(x: mouse.x, y: mouse.y, width: 0, height: 0)
      let left = min(max(statusFrame.minX, visible.minX), max(visible.minX, visible.maxX - width))
      itemFrame = NSRect(x: left, y: mouse.y - 7.5, width: width, height: 15)
    }
    let availableWidth = max(
      0, max(itemFrame.minX - 3 - visible.minX - 12, visible.maxX - 12 - itemFrame.maxX - 3))
    let availableHeight = min(visible.height * 0.618, max(0, visible.height - 24))
    guard
      let layout = TrayPresentation.previewLayout(
        text, availableWidth: availableWidth, availableHeight: availableHeight)
    else { return }
    let panel = preview ?? makePreview()
    let frame = NSRect(
      origin: TrayPresentation.previewOrigin(screen: visible, item: itemFrame, size: layout.size),
      size: layout.size)
    panel.setFrame(frame, display: true)
    previewTextView?.frame.size = layout.size
    previewTextView?.string = layout.text
    panel.orderFrontRegardless()
  }

  private func makePreview() -> NSPanel {
    let frame = NSRect(x: 0, y: 0, width: 380, height: 36)
    let panel = NSPanel(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    panel.level = .popUpMenu
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.animationBehavior = .none
    panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
    let effect = NSVisualEffectView(frame: frame)
    effect.autoresizingMask = [.width, .height]
    effect.material = .menu
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.wantsLayer = true
    effect.layer?.cornerRadius = 6
    effect.layer?.masksToBounds = true
    let text = NSTextView(frame: frame)
    text.autoresizingMask = [.width, .height]
    text.isEditable = false
    text.isSelectable = false
    text.isRichText = false
    text.importsGraphics = false
    text.drawsBackground = false
    text.textColor = .labelColor
    text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    text.textContainerInset = NSSize(width: 8, height: 6)
    text.isVerticallyResizable = false
    text.isHorizontallyResizable = false
    text.isContinuousSpellCheckingEnabled = false
    text.isAutomaticSpellingCorrectionEnabled = false
    text.isAutomaticQuoteSubstitutionEnabled = false
    text.isAutomaticLinkDetectionEnabled = false
    text.isAutomaticDataDetectionEnabled = false
    text.textContainer?.widthTracksTextView = true
    text.textContainer?.lineFragmentPadding = 0
    effect.addSubview(text)
    panel.contentView = effect
    preview = panel
    previewTextView = text
    return panel
  }
}
