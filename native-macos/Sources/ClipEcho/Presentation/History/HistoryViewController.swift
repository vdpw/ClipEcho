import AppKit
import ClipEchoCore

@MainActor
final class HistoryViewController: NSViewController, NSTextFieldDelegate {
  private unowned let controller: AppController
  private let scroll = NSScrollView()
  private let document = HistoryDocumentView()
  private let dragStrip = HistoryDragStrip()
  private let search = HistorySearchView()
  private let titleLabel = HistoryLabel(size: 20, weight: .bold, lineHeight: 26, singleLine: true)
  private let count = HistoryCountView()
  private let footer = HistoryLabel(size: 12.16)
  private let loadMoreButton = HistoryActionButton(title: "", label: "", style: .secondary)
  private let empty = HistoryEmptyView()
  private let errorNotice = HistoryNoticeView(warning: false)
  private let captureNotice = HistoryNoticeView(warning: true)
  private var headings: [HistoryLabel] = []
  private var items: [HistoryItem] = []
  private var cards: [String: HistoryCardView] = [:]
  private var expanded = Set<String>()
  private var detailCache: [String: InlineHistoryDetail] = [:]
  private var cacheOrder: [String] = []
  private var detailTasks: [String: Task<Void, Never>] = [:]
  private var detailTaskIDs: [String: UUID] = [:]
  private var detailTaskOrder: [String] = []
  private var detailGeneration = 0
  private var nextCursor: HistoryCursor?
  private var totalCount: Int64 = 0
  private var query = ""
  private var loading = true
  private var refreshing = false
  private var loadingMore = false
  private var automaticLoadPaused = false
  private var generation = 0
  private var loadTask: Task<Void, Never>?
  private var searchTask: Task<Void, Never>?
  private var feedbackTask: Task<Void, Never>?
  private var animationTask: Task<Void, Never>?
  private var copiedHash: String?
  private var restoring = Set<String>()
  private var pinning = Set<String>()
  private var deleting = Set<String>()
  private var layingOut = false
  private var retryAction: (() -> Void)?
  private var lastCompact: Bool
  private var pendingSearchFocus = false
  init(controller: AppController) {
    self.controller = controller
    lastCompact = controller.settings.compactMode
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { nil }
  private func t(_ key: String) -> String {
    L10n.string(key, language: controller.settings.language)
  }
  override func loadView() {
    let root = HistoryRootView()
    root.onLayout = { [weak self] in self?.layoutContent() }
    view = root
    titleLabel.kerning = -0.7
    dragStrip.material = .titlebar
    dragStrip.blendingMode = .withinWindow
    dragStrip.state = .active
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = document
    scroll.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(didScroll), name: NSView.boundsDidChangeNotification,
      object: scroll.contentView)
    search.input.delegate = self
    search.onClear = { [weak self] in
      guard let self else { return }
      searchTask?.cancel()
      search.input.stringValue = ""
      query = ""
      resetDetails()
      reload(reset: true)
      focusSearch()
    }
    errorNotice.onDismiss = { [weak self] in
      self?.errorNotice.isHidden = true
      self?.layoutContent()
    }
    errorNotice.onRetry = { [weak self] in
      guard let self else { return }
      if let retryAction { retryAction() } else { reload() }
    }
    captureNotice.onDismiss = { [weak self] in
      self?.captureNotice.isHidden = true
      self?.layoutContent()
    }
    loadMoreButton.onClick = { [weak self] in self?.loadMore() }
    for child in [dragStrip, scroll, search] { view.addSubview(child) }
    for child in [titleLabel, count, footer, loadMoreButton, empty, errorNotice, captureNotice] {
      document.addSubview(child)
    }
    errorNotice.isHidden = true
    captureNotice.isHidden = true
    document.setAccessibilityLabel(t("clipboardHistory"))
    reload(reset: true)
  }
  override func viewDidAppear() {
    super.viewDidAppear()
    if pendingSearchFocus {
      focusSearch()
    } else if search.input.currentEditor() == nil {
      view.window?.makeFirstResponder(document)
    }
  }
  func resetSession() {
    pendingSearchFocus = false
    loadTask?.cancel()
    generation += 1
    loadingMore = false
    refreshing = false
    searchTask?.cancel()
    feedbackTask?.cancel()
    animationTask?.cancel()
    search.input.stringValue = ""
    query = ""
    copiedHash = nil
    items = []
    nextCursor = nil
    totalCount = 0
    loading = true
    resetDetails()
    errorNotice.isHidden = true
    captureNotice.isHidden = true
    retryAction = nil
    if isViewLoaded {
      rebuildCards()
      layoutContent()
    }
  }
  func focusSearch() {
    pendingSearchFocus = true
    guard isViewLoaded, let window = view.window, window.makeFirstResponder(search.input)
    else { return }
    search.input.selectText(nil)
    pendingSearchFocus = false
  }
  func showError(_ message: String) {
    guard isViewLoaded else { return }
    errorNotice.message = message
    errorNotice.canRetry = true
    errorNotice.isHidden = false
    layoutContent()
  }
  func showCaptureNotice(_ message: String) {
    guard isViewLoaded else { return }
    captureNotice.message = message
    captureNotice.isHidden = false
    layoutContent()
  }
  private func resetDetails() {
    for task in detailTasks.values { task.cancel() }
    detailTasks = [:]
    detailTaskIDs = [:]
    detailTaskOrder = []
    detailCache = [:]
    cacheOrder = []
    expanded = []
    detailGeneration += 1
  }
  private struct Anchor {
    let hash: String?
    let offset: CGFloat
    let scrollTop: CGFloat
  }
  private func captureAnchor() -> Anchor {
    let y = scroll.contentView.bounds.minY
    if let item = items.first(where: { (cards[$0.contentHash]?.frame.maxY ?? 0) > y }),
      let card = cards[item.contentHash]
    {
      return Anchor(hash: item.contentHash, offset: card.frame.minY - y, scrollTop: y)
    }
    return Anchor(hash: nil, offset: 0, scrollTop: y)
  }
  private func restoreAnchor(_ anchor: Anchor) {
    let y =
      anchor.hash.flatMap { cards[$0] }.map { $0.frame.minY - anchor.offset } ?? anchor.scrollTop
    scrollTo(y)
  }
  private func layoutPreservingAnchor() {
    let anchor = captureAnchor()
    layoutContent()
    restoreAnchor(anchor)
  }
  /// Inspection-only identities let isolated self-tests detect rebuilding an
  /// unchanged card (and its WebKit process) after a refresh or another page.
  func diagnosticCardIdentity(contentHash: String) -> ObjectIdentifier? {
    cards[contentHash].map(ObjectIdentifier.init)
  }
  func reload(reset: Bool = false, scrollToTop: Bool = false) {
    guard isViewLoaded else { return }
    loadTask?.cancel()
    generation += 1
    let request = generation
    refreshing = true
    let requestQuery = query
    let target = reset ? 50 : max(50, items.count)
    let anchor = captureAnchor()
    if lastCompact != controller.settings.compactMode {
      lastCompact = controller.settings.compactMode
      resetDetails()
    }
    if reset {
      loading = true
      items = []
      nextCursor = nil
      totalCount = 0
      rebuildCards()
      layoutContent()
    }
    automaticLoadPaused = false
    loadingMore = false
    loadTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if generation == request { refreshing = false }
      }
      do {
        var replacement: [HistoryItem] = []
        var cursor: HistoryCursor?
        var total: Int64 = 0
        repeat {
          let page = try await controller.history.page(
            cursor: cursor, limit: 50, query: requestQuery)
          guard !Task.isCancelled, generation == request else { return }
          replacement.append(contentsOf: page.items)
          cursor = page.nextCursor
          total = page.totalCount
        } while cursor != nil && replacement.count < target
        items = replacement
        nextCursor = cursor
        totalCount = total
        loading = false
        automaticLoadPaused = false
        retainDetails()
        rebuildCards()
        layoutContent()
        if reset {
          scrollTo(0)
        } else if scrollToTop {
          animateToTop()
        } else {
          restoreAnchor(anchor)
        }
      } catch {
        guard !Task.isCancelled, generation == request else { return }
        loading = false
        automaticLoadPaused = true
        rebuildCards()
        showError(t("historyLoadError"))
        layoutContent()
      }
    }
  }
  private func retainDetails() {
    let hashes = Set(items.map(\.contentHash))
    detailCache = detailCache.filter { hashes.contains($0.key) }
    cacheOrder = cacheOrder.filter { hashes.contains($0) }
    for (hash, task) in detailTasks where !hashes.contains(hash) {
      task.cancel()
      detailTasks.removeValue(forKey: hash)
      detailTaskIDs.removeValue(forKey: hash)
      detailTaskOrder.removeAll { $0 == hash }
    }
  }
  private func rebuildCards() {
    let previousCards = cards
    cards = [:]
    for heading in headings { heading.removeFromSuperview() }
    headings = []
    for (index, item) in items.enumerated() {
      if index == 0 || items[index - 1].isPinned != item.isPinned {
        let heading = HistoryLabel(
          t(item.isPinned ? "pinned" : "recentHistory"), size: 11.68, weight: .semibold,
          lineHeight: 16.352, singleLine: true)
        heading.kerning = 0.1168
        headings.append(heading)
        document.addSubview(heading)
      }
      let card: HistoryCardView
      if let previous = previousCards[item.contentHash],
        previous.matches(item: item, language: controller.settings.language, query: query)
      {
        card = previous
      } else {
        card = HistoryCardView(item: item, language: controller.settings.language, query: query)
      }
      card.expanded = expanded.contains(item.contentHash)
      card.copied = copiedHash == item.contentHash
      card.restoring = restoring.contains(item.contentHash)
      card.pinning = pinning.contains(item.contentHash)
      card.deleting = deleting.contains(item.contentHash)
      card.onToggle = { [weak self] in self?.toggleExpansion(item) }
      card.onRestore = { [weak self] in self?.restore(item) }
      card.onPin = { [weak self] in self?.togglePin(item) }
      card.onDelete = { [weak self] in self?.delete(item) }
      card.onRetry = { [weak self] in self?.loadDetail(item, retry: true) }
      card.onHeightChanged = { [weak self] in
        self?.layoutPreservingAnchor()
      }
      if let detail = detailCache[item.contentHash] {
        card.detail = detail
        card.detailState = detail.hasContent ? 3 : 0
      } else if detailTasks[item.contentHash] != nil {
        card.detailState = 1
      } else if card.detail != nil || card.detailState != 0 {
        card.clearDetail()
      }
      card.refresh()
      if card.superview == nil { document.addSubview(card) }
      cards[item.contentHash] = card
    }
    for (hash, card) in previousCards where cards[hash] !== card { card.removeFromSuperview() }
    titleLabel.stringValue = t("clipboardHistory")
    errorNotice.language = controller.settings.language
    captureNotice.language = controller.settings.language
    search.input.placeholderString = t("searchClipboardHistory")
    search.input.setAccessibilityLabel(t("searchClipboardHistory"))
    search.clearButton.setAccessibilityLabel(t("clearSearch"))
    count.value = String(totalCount)
    footer.stringValue = L10n.format(
      query.isEmpty ? "loadedHistoryCount" : "loadedSearchCount",
      language: controller.settings.language, args: [String(items.count), String(totalCount)])
    loadMoreButton.title = t(loadingMore ? "loadingMore" : "loadMore")
    loadMoreButton.setAccessibilityLabel(loadMoreButton.title)
    loadMoreButton.isEnabled = !loadingMore
    loadMoreButton.isHidden = nextCursor == nil
    empty.title = loading ? "" : t(query.isEmpty ? "emptyHistory" : "noSearchResults")
    empty.message =
      loading
      ? t("loadingHistory")
      : query.isEmpty
        ? t(controller.settings.compactMode ? "emptyHistoryCompact" : "emptyHistoryAll")
        : L10n.format(
          "noSearchResultsDescription", language: controller.settings.language, args: [query])
    empty.isHidden = !loading && !items.isEmpty
    footer.isHidden = loading || items.isEmpty
    view.window?.recalculateKeyViewLoop()
  }
  private func layoutContent() {
    guard isViewLoaded, !layingOut else { return }
    layingOut = true
    defer { layingOut = false }
    let size = view.bounds.size
    dragStrip.frame = NSRect(x: 0, y: 0, width: size.width, height: 40)
    scroll.frame = NSRect(x: 0, y: 40, width: size.width, height: max(0, size.height - 40))
    let width = scroll.contentSize.width
    let inset: CGFloat = width <= 560 ? 14 : 20
    let bodyWidth = max(1, width - 2 * inset)
    titleLabel.textColor = HistoryVisual.text(view)
    footer.textColor = HistoryVisual.secondary(view)
    titleLabel.frame = NSRect(
      x: inset + 2, y: 14,
      width: titleLabel.textWidth,
      height: 30)
    count.frame = NSRect(x: titleLabel.frame.maxX + 9, y: 19, width: count.desiredWidth, height: 20)
    var y: CGFloat = 58
    for notice in [errorNotice, captureNotice] where !notice.isHidden {
      let h = notice.desiredHeight(width: bodyWidth)
      notice.frame = NSRect(x: inset, y: y, width: bodyWidth, height: h)
      y += h + 14
    }
    let searchY = y
    y += 42 + 14
    var headingIndex = 0
    if loading || items.isEmpty {
      empty.frame = NSRect(x: inset, y: y, width: bodyWidth, height: loading ? 66 : 172)
      empty.layoutSubtreeIfNeeded()
      y += empty.frame.height
    } else {
      for (index, item) in items.enumerated() {
        if index == 0 || items[index - 1].isPinned != item.isPinned {
          if index > 0 { y += 11 }
          let heading = headings[headingIndex]
          heading.textColor = HistoryVisual.secondary(view)
          heading.frame = NSRect(x: inset + 2, y: y, width: bodyWidth - 4, height: 16.352)
          headingIndex += 1
          y += 24.352
        }
        if let card = cards[item.contentHash] {
          let h = card.desiredHeight(width: bodyWidth)
          card.frame = NSRect(x: inset, y: y, width: bodyWidth, height: h)
          card.layoutSubtreeIfNeeded()
          y += h + 7
        }
      }
      y += 7
      footer.frame = NSRect(x: inset, y: y + 8, width: max(1, bodyWidth - 120), height: 20)
      loadMoreButton.frame = NSRect(x: inset + bodyWidth - 112, y: y, width: 112, height: 32)
      y += 36
    }
    document.frame = NSRect(
      x: 0, y: 0, width: width, height: max(scroll.contentSize.height, y + 24))
    document.needsDisplay = true
    search.frame = NSRect(
      x: inset, y: 40 + max(24, searchY - scroll.contentView.bounds.minY), width: bodyWidth,
      height: 42)
    search.layoutSubtreeIfNeeded()
  }
  @objc private func didScroll() {
    layoutContent()
    guard !loading, !refreshing, !loadingMore, !automaticLoadPaused, nextCursor != nil else {
      return
    }
    if scroll.contentView.bounds.maxY + 320 >= document.frame.height { loadMore() }
  }
  private func loadMore() {
    guard !refreshing, !loadingMore, !loading, let cursor = nextCursor else { return }
    loadingMore = true
    let request = generation
    let requestQuery = query
    rebuildFooter()
    loadTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if generation == request {
          loadingMore = false
          rebuildFooter()
        }
      }
      do {
        let page = try await controller.history.page(cursor: cursor, limit: 50, query: requestQuery)
        guard !Task.isCancelled, generation == request else { return }
        let known = Set(items.map(\.contentHash))
        items.append(contentsOf: page.items.filter { !known.contains($0.contentHash) })
        nextCursor = page.nextCursor
        totalCount = page.totalCount
        automaticLoadPaused = false
        rebuildCards()
        layoutContent()
      } catch {
        guard !Task.isCancelled, generation == request else { return }
        automaticLoadPaused = true
        showError(t("historyLoadError"))
      }
    }
  }
  private func rebuildFooter() {
    loadMoreButton.title = t(loadingMore ? "loadingMore" : "loadMore")
    loadMoreButton.isEnabled = !loadingMore
    loadMoreButton.isHidden = nextCursor == nil
  }
  private func toggleExpansion(_ item: HistoryItem) {
    if expanded.contains(item.contentHash) {
      expanded.remove(item.contentHash)
    } else {
      expanded.insert(item.contentHash)
    }
    guard let card = cards[item.contentHash] else { return }
    card.expanded = expanded.contains(item.contentHash)
    card.refresh()
    layoutPreservingAnchor()
    if card.expanded, !controller.settings.compactMode, item.dataType != "text",
      detailCache[item.contentHash] == nil
    {
      loadDetail(item)
    }
  }
  private func loadDetail(_ item: HistoryItem, retry: Bool = false) {
    let hash = item.contentHash
    guard detailTasks[hash] == nil else { return }
    if retry { cards[hash]?.clearDetail() }
    let detailRequest = detailGeneration
    let requestID = UUID()
    while detailTaskOrder.count >= 12 {
      let oldest = detailTaskOrder.removeFirst()
      detailTasks.removeValue(forKey: oldest)?.cancel()
      detailTaskIDs.removeValue(forKey: oldest)
      cards[oldest]?.clearDetail()
    }
    detailTaskIDs[hash] = requestID
    detailTaskOrder.append(hash)
    cards[hash]?.detailState = 1
    cards[hash]?.refresh()
    layoutPreservingAnchor()
    detailTasks[hash] = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if detailTaskIDs[hash] == requestID {
          detailTasks.removeValue(forKey: hash)
          detailTaskIDs.removeValue(forKey: hash)
          detailTaskOrder.removeAll { $0 == hash }
        }
      }
      do {
        guard let stored = try await controller.history.event(contentHash: hash) else {
          throw StorageError.invalidEvent
        }
        let detail = try await Task.detached(priority: .userInitiated) {
          try InlineHistoryDetail.build(stored)
        }.value
        guard !Task.isCancelled, detailGeneration == detailRequest, detailTaskIDs[hash] == requestID
        else { return }
        detailCache[hash] = detail
        cacheOrder.removeAll { $0 == hash }
        cacheOrder.append(hash)
        while cacheOrder.count > 12 {
          let evicted = cacheOrder.removeFirst()
          detailCache.removeValue(forKey: evicted)
          cards[evicted]?.clearDetail()
        }
        cards[hash]?.detail = detail
        cards[hash]?.detailState = detail.hasContent ? 3 : 0
        cards[hash]?.refresh()
        layoutPreservingAnchor()
      } catch {
        guard !Task.isCancelled, detailGeneration == detailRequest, detailTaskIDs[hash] == requestID
        else { return }
        cards[hash]?.detailState = 2
        cards[hash]?.refresh()
        layoutPreservingAnchor()
      }
    }
  }
  private func togglePin(_ item: HistoryItem) {
    let hash = item.contentHash
    guard !deleting.contains(hash), pinning.insert(hash).inserted else { return }
    cards[hash]?.pinning = true
    cards[hash]?.refresh()
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        pinning.remove(hash)
        cards[hash]?.pinning = false
        cards[hash]?.refresh()
      }
      retryAction = { [weak self] in self?.togglePin(item) }
      if await controller.togglePinAndWait(item) {
        errorNotice.isHidden = true
        retryAction = nil
        reload(scrollToTop: !item.isPinned)
      }
    }
  }
  private func delete(_ item: HistoryItem) {
    let hash = item.contentHash
    guard !pinning.contains(hash), !deleting.contains(hash) else { return }
    if item.isPinned {
      let message =
        t("deletePinnedConfirmationDescription")
        + (controller.settings.compactMode ? "\n\n" + t("deletePinnedCompactDescription") : "")
      guard
        controller.confirm(
          title: t("deletePinnedConfirmationTitle"), message: message, confirmLabel: t("deleteItem")
        )
      else { return }
    }
    deleting.insert(hash)
    cards[hash]?.deleting = true
    cards[hash]?.refresh()
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        deleting.remove(hash)
        cards[hash]?.deleting = false
        cards[hash]?.refresh()
      }
      retryAction = { [weak self] in self?.delete(item) }
      if await controller.deleteAndWait(item) {
        detailCache.removeValue(forKey: hash)
        expanded.remove(hash)
        errorNotice.isHidden = true
        retryAction = nil
        reload()
        view.window?.makeFirstResponder(document)
      }
    }
  }
  private func restore(_ item: HistoryItem) {
    let hash = item.contentHash
    guard !deleting.contains(hash), restoring.insert(hash).inserted else { return }
    cards[hash]?.restoring = true
    cards[hash]?.refresh()
    let move = controller.settings.moveRestoredItemToTop && items.first?.contentHash != hash
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        restoring.remove(hash)
        cards[hash]?.restoring = false
        cards[hash]?.refresh()
      }
      retryAction = { [weak self] in self?.restore(item) }
      let outcome = await controller.restoreWithOutcome(item)
      if outcome != .failed {
        if outcome == .copied {
          errorNotice.isHidden = true
        } else {
          errorNotice.canRetry = false
          errorNotice.needsLayout = true
        }
        retryAction = nil
        if let previous = copiedHash {
          cards[previous]?.copied = false
          cards[previous]?.refresh()
        }
        copiedHash = hash
        cards[hash]?.copied = true
        cards[hash]?.refresh()
        feedbackTask?.cancel()
        feedbackTask = Task { @MainActor [weak self] in
          try? await Task.sleep(for: .milliseconds(1_400))
          guard !Task.isCancelled, let self else { return }
          copiedHash = nil
          cards[hash]?.copied = false
          cards[hash]?.refresh()
        }
        if move && outcome == .copied { reload(scrollToTop: true) } else { layoutContent() }
      }
    }
  }
  func controlTextDidChange(_ notification: Notification) {
    guard notification.object as? NSTextField === search.input else { return }
    if search.input.stringValue.count > 256 {
      search.input.stringValue = String(search.input.stringValue.prefix(256))
    }
    search.needsLayout = true
    searchTask?.cancel()
    searchTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(180))
      guard !Task.isCancelled, let self else { return }
      let value = search.input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard value != query else { return }
      query = value
      resetDetails()
      reload(reset: true)
    }
  }
  func controlTextDidBeginEditing(_ notification: Notification) { search.focused = true }
  func controlTextDidEndEditing(_ notification: Notification) { search.focused = false }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    if selector == #selector(NSResponder.cancelOperation(_:)) {
      searchTask?.cancel()
      if !search.input.stringValue.isEmpty {
        search.input.stringValue = ""
        query = ""
        resetDetails()
        reload(reset: true)
        search.needsLayout = true
      } else {
        view.window?.makeFirstResponder(document)
      }
      return true
    }
    return selector == #selector(NSResponder.insertNewline(_:))
  }
  private func scrollTo(_ y: CGFloat) {
    scroll.contentView.scroll(
      to: NSPoint(x: 0, y: max(0, min(y, document.frame.height - scroll.contentSize.height))))
    scroll.reflectScrolledClipView(scroll.contentView)
    layoutContent()
  }
  private func animateToTop() {
    animationTask?.cancel()
    let start = scroll.contentView.bounds.minY
    if start <= 0 || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      scrollTo(0)
      return
    }
    animationTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let began = Date.timeIntervalSinceReferenceDate
      while !Task.isCancelled {
        let progress = min(1, (Date.timeIntervalSinceReferenceDate - began) / 0.32)
        scrollTo(start * pow(1 - progress, 3))
        if progress >= 1 { break }
        try? await Task.sleep(for: .milliseconds(16))
      }
    }
  }
}
