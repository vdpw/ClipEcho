import AppKit
import ClipEchoCore

@MainActor
final class SettingsViewController: NSViewController, NSTextFieldDelegate {
  private enum Category: Int, CaseIterable {
    case general, appearance, clipboard, menuBar
    var key: String {
      ["generalSettings", "appearanceSettings", "clipboardSettings", "menuBarSettings"][rawValue]
    }
  }
  private unowned let controller: AppController
  private let navigation = SettingsSurface()
  private let contentScroll = NSScrollView()
  private let bodyStack = FlippedStackView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let descriptionLabel = NSTextField(wrappingLabelWithString: "")
  private var navigationWidth: NSLayoutConstraint!
  private var categoryButtons: [SettingsCategoryButton] = []
  private var backButton: SettingsButton!
  private let navigationTitle = NSTextField(labelWithString: "")
  private var category = Category.general
  private var drafts: [String: String] = [:]
  private var savedNumbers: [String: Int64] = [:]
  private var numericFields: [String: SettingsNumberField] = [:]
  private var numericButtons: [String: SettingsButton] = [:]
  private var numericErrors: [String: NSTextField] = [:]
  private var numericErrorRows: [String: NSStackView] = [:]
  private var controls: [NSControl] = []
  private var optimistic: [String: String] = [:]
  private var busy = false
  private var pendingTheme: String?
  private var themeSaveTask: Task<Void, Never>?
  private var moving = false
  private var clearing = false
  private var errorMessage = ""
  private var retryAction: (@MainActor () -> Void)?
  private var helpBubble: SettingsHelpBubble?
  private var helpObservation: SettingsHelpObservation?
  private weak var helpAnchor: NSButton?
  private let errorHost = FlippedStackView()
  private var focusObserver: SettingsWindowObservation?

  init(controller: AppController) {
    self.controller = controller
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { nil }
  private func t(_ key: String) -> String {
    L10n.string(key, language: controller.settings.language)
  }
  private func f(_ key: String, _ args: [String]) -> String {
    L10n.format(key, language: controller.settings.language, args: args)
  }

  override func loadView() {
    view = SettingsSurface()
    navigation.color = SettingsPalette.sidebar
    navigation.translatesAutoresizingMaskIntoConstraints = false
    navigationWidth = navigation.widthAnchor.constraint(equalToConstant: 186)
    navigationWidth.isActive = true
    view.addSubview(navigation)

    let drag = SettingsDragRegion()
    drag.translatesAutoresizingMaskIntoConstraints = false
    navigation.addSubview(drag)
    let sidebarScroll = NSScrollView()
    sidebarScroll.drawsBackground = false
    sidebarScroll.hasVerticalScroller = true
    sidebarScroll.autohidesScrollers = true
    sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
    navigation.addSubview(sidebarScroll)
    let sideStack = FlippedStackView()
    sideStack.orientation = .vertical
    sideStack.alignment = .leading
    sideStack.spacing = 0
    sideStack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 13, right: 10)
    sideStack.translatesAutoresizingMaskIntoConstraints = false
    sidebarScroll.documentView = sideStack
    backButton = SettingsButton(t("backToHistoryShort"), style: .back, symbol: "arrow.left") {
      [weak self] in
      self?.closeHelp()
      self?.controller.showHistory()
    }
    backButton.toolTip = t("backToHistory")
    backButton.setAccessibilityLabel(t("backToHistory"))
    sideStack.addArrangedSubview(backButton)
    navigationTitle.font = .systemFont(ofSize: 11.2, weight: .semibold)
    navigationTitle.textColor = SettingsPalette.tertiary
    let titleWrap = NSView()
    navigationTitle.translatesAutoresizingMaskIntoConstraints = false
    titleWrap.addSubview(navigationTitle)
    let bodyWidth = bodyStack.widthAnchor.constraint(equalTo: contentScroll.contentView.widthAnchor)
    // Let the window's current-size constraint (priority 500) win once the
    // body reaches its maximum width, without capping the whole window.
    bodyWidth.priority = NSLayoutConstraint.Priority(499)
    NSLayoutConstraint.activate([
      navigationTitle.leadingAnchor.constraint(equalTo: titleWrap.leadingAnchor, constant: 8),
      navigationTitle.trailingAnchor.constraint(
        lessThanOrEqualTo: titleWrap.trailingAnchor, constant: -8),
      navigationTitle.topAnchor.constraint(equalTo: titleWrap.topAnchor, constant: 25),
      navigationTitle.bottomAnchor.constraint(equalTo: titleWrap.bottomAnchor, constant: -10),
    ])
    sideStack.addArrangedSubview(titleWrap)
    titleWrap.widthAnchor.constraint(equalTo: sideStack.widthAnchor, constant: -20).isActive = true
    let navStack = NSStackView()
    navStack.orientation = .vertical
    navStack.alignment = .leading
    navStack.spacing = 3
    for item in Category.allCases {
      let button = SettingsCategoryButton(index: item.rawValue, title: t(item.key)) { [weak self] in
        self?.selectCategory(item)
      }
      categoryButtons.append(button)
      navStack.addArrangedSubview(button)
      button.widthAnchor.constraint(equalTo: navStack.widthAnchor).isActive = true
    }
    sideStack.addArrangedSubview(navStack)
    navStack.widthAnchor.constraint(equalTo: sideStack.widthAnchor, constant: -20).isActive = true
    NSLayoutConstraint.activate([
      drag.topAnchor.constraint(equalTo: navigation.topAnchor),
      drag.leadingAnchor.constraint(equalTo: navigation.leadingAnchor),
      drag.trailingAnchor.constraint(equalTo: navigation.trailingAnchor),
      drag.heightAnchor.constraint(equalToConstant: 44),
      sidebarScroll.topAnchor.constraint(equalTo: drag.bottomAnchor),
      sidebarScroll.bottomAnchor.constraint(equalTo: navigation.bottomAnchor),
      sidebarScroll.leadingAnchor.constraint(equalTo: navigation.leadingAnchor),
      sidebarScroll.trailingAnchor.constraint(equalTo: navigation.trailingAnchor),
      sideStack.widthAnchor.constraint(equalTo: sidebarScroll.contentView.widthAnchor),
      sideStack.leadingAnchor.constraint(equalTo: sidebarScroll.contentView.leadingAnchor),
      sideStack.topAnchor.constraint(equalTo: sidebarScroll.contentView.topAnchor),
    ])

    let pane = SettingsSurface()
    pane.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(pane)
    let header = SettingsHeaderDragSurface()
    header.translatesAutoresizingMaskIntoConstraints = false
    pane.addSubview(header)
    titleLabel.font = .systemFont(ofSize: 15.5, weight: .semibold)
    titleLabel.textColor = SettingsPalette.primary
    descriptionLabel.font = .systemFont(ofSize: 13)
    descriptionLabel.textColor = SettingsPalette.secondary
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
    header.addSubview(titleLabel)
    header.addSubview(descriptionLabel)
    contentScroll.hasVerticalScroller = true
    contentScroll.autohidesScrollers = true
    contentScroll.drawsBackground = false
    contentScroll.translatesAutoresizingMaskIntoConstraints = false
    pane.addSubview(contentScroll)
    bodyStack.orientation = .vertical
    bodyStack.alignment = .leading
    bodyStack.spacing = 10
    bodyStack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 28, right: 20)
    bodyStack.translatesAutoresizingMaskIntoConstraints = false
    contentScroll.documentView = bodyStack
    NSLayoutConstraint.activate([
      navigation.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      navigation.topAnchor.constraint(equalTo: view.topAnchor),
      navigation.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      pane.leadingAnchor.constraint(equalTo: navigation.trailingAnchor),
      pane.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      pane.topAnchor.constraint(equalTo: view.topAnchor),
      pane.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      header.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
      header.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
      header.topAnchor.constraint(equalTo: pane.topAnchor),
      header.heightAnchor.constraint(equalToConstant: 76),
      titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -20),
      titleLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 16),
      titleLabel.heightAnchor.constraint(equalToConstant: 21),
      descriptionLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
      descriptionLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20),
      descriptionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
      contentScroll.topAnchor.constraint(equalTo: header.bottomAnchor),
      contentScroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
      contentScroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
      contentScroll.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
      bodyWidth,
      bodyStack.widthAnchor.constraint(lessThanOrEqualTo: contentScroll.contentView.widthAnchor),
      bodyStack.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
      bodyStack.leadingAnchor.constraint(equalTo: contentScroll.contentView.leadingAnchor),
      bodyStack.topAnchor.constraint(equalTo: contentScroll.contentView.topAnchor),
    ])
  }
  override func viewDidLoad() {
    super.viewDidLoad()
    reload()
  }
  override func viewDidLayout() {
    super.viewDidLayout()
    navigationWidth.constant = min(232, max(184, view.bounds.width * 0.31))
    positionHelp()
  }
  override func viewDidAppear() {
    super.viewDidAppear()
    focusObserver = SettingsWindowObservation(window: view.window) { [weak self] in
      for button in self?.categoryButtons ?? [] { button.needsDisplay = true }
    }
  }
  override func viewWillDisappear() {
    super.viewWillDisappear()
    closeHelp()
    focusObserver = nil
  }

  func reload() {
    guard isViewLoaded else { return }
    saveDrafts()
    let values: [String: Int64] = [
      "max_items": Int64(controller.settings.maxItems),
      "max_history_bytes": controller.settings.maxHistoryBytes / 1_048_576,
      "max_event_bytes": controller.settings.maxEventBytes / 1_048_576,
      "menu_bar_item_limit": Int64(controller.settings.menuBarItemLimit),
    ]
    for (key, value) in values {
      if savedNumbers[key] != value { drafts[key] = String(value) }
    }
    savedNumbers = values
    backButton.title = t("backToHistoryShort")
    backButton.invalidateIntrinsicContentSize()
    backButton.toolTip = t("backToHistory")
    backButton.setAccessibilityLabel(t("backToHistory"))
    navigationTitle.stringValue = t("settings")
    for item in Category.allCases {
      categoryButtons[item.rawValue].title = t(item.key)
      categoryButtons[item.rawValue].setAccessibilityLabel(t(item.key))
    }
    rebuildCategory()
  }

  /// Errors stay within the same settings pane and never expose backend diagnostics.
  func showError(_ message: String) {
    errorMessage = message
    if isViewLoaded { rebuildError() }
  }

  /// React mounts a fresh settings page whenever history navigates here.
  /// Operation state stays with the app while page drafts and navigation restart.
  func resetSession() {
    closeHelp()
    category = .general
    drafts.removeAll()
    savedNumbers.removeAll()
    numericFields.removeAll()
    numericButtons.removeAll()
    numericErrors.removeAll()
    numericErrorRows.removeAll()
    if isViewLoaded {
      contentScroll.contentView.scroll(to: .zero)
      contentScroll.reflectScrolledClipView(contentScroll.contentView)
    }
  }

  private func saveDrafts() {
    for (key, field) in numericFields { drafts[key] = field.stringValue }
  }
  private func selectCategory(_ item: Category) {
    guard category != item else { return }
    saveDrafts()
    closeHelp()
    category = item
    rebuildCategory()
    contentScroll.contentView.scroll(to: .zero)
    contentScroll.reflectScrolledClipView(contentScroll.contentView)
  }
  private func rebuildCategory() {
    let scroll = contentScroll.contentView.bounds.origin
    titleLabel.stringValue = t(category.key)
    descriptionLabel.stringValue = t(category.key + "Description")
    for (index, button) in categoryButtons.enumerated() {
      button.selected = index == category.rawValue
    }
    for child in bodyStack.arrangedSubviews {
      bodyStack.removeArrangedSubview(child)
      child.removeFromSuperview()
    }
    controls = []
    numericFields = [:]
    numericButtons = [:]
    numericErrors = [:]
    numericErrorRows = [:]
    errorHost.orientation = .vertical
    errorHost.alignment = .leading
    errorHost.spacing = 0
    addBody(errorHost)
    rebuildError()
    let settings = controller.settings
    switch category {
    case .general:
      addGroup(rows: [
        languageRow(),
        switchRow(title: t("launchAtLogin"), value: controller.launchAtLoginEnabled, compact: true)
        { [weak self] enabled in
          guard let self else { return }
          self.showError("")
          if !self.controller.setLaunchAtLogin(enabled) {
            self.showError(self.t("launchAtLoginUpdateError"))
          }
          self.reload()
        },
      ])
    case .appearance:
      let title = label(t("theme"))
      title.toolTip = t("themeDescription")
      let choices = NSStackView()
      choices.orientation = .horizontal
      choices.alignment = .top
      choices.spacing = 12
      let selected = optimistic["theme"] ?? settings.theme
      for theme in ["light", "dark", "system"] {
        let button = SettingsThemeButton(
          theme: theme, title: t("theme" + theme.prefix(1).uppercased() + theme.dropFirst()),
          chosen: selected == theme
        ) { [weak self] in self?.saveSetting("theme", value: theme) }
        button.identifier = NSUserInterfaceItemIdentifier("theme:" + theme)
        controls.append(button)
        button.isEnabled = canChooseTheme
        choices.addArrangedSubview(button)
      }
      choices.widthAnchor.constraint(equalToConstant: 228).isActive = true
      let row = makeRow(copy: title, control: choices, minimum: 93.3, padding: 14)
      (row as? NSStackView)?.alignment = .top
      addGroup(rows: [row])
    case .clipboard:
      heading(t("behaviorSettings"), first: true)
      let compact = optimistic["compact_mode"].map { $0 == "true" } ?? settings.compactMode
      let restore =
        optimistic["move_restored_item_to_top"].map { $0 == "true" }
        ?? settings.moveRestoredItemToTop
      addGroup(rows: [
        switchRow(
          title: t("compactMode"),
          description: t(compact ? "compactModeEnabled" : "compactModeDisabled"),
          descriptionSymbol: "textformat", value: compact, key: "compact_mode"
        ) { [weak self] in self?.saveSetting("compact_mode", value: String($0)) },
        switchRow(
          title: t("moveRestoredItemsToTop"),
          description: t(restore ? "restoreOrderingEnabled" : "restoreOrderingDisabled"),
          descriptionSymbol: "arrow.up.arrow.down", value: restore, key: "move_restored_item_to_top"
        ) { [weak self] in self?.saveSetting("move_restored_item_to_top", value: String($0)) },
      ])
      heading(t("storageSettings"))
      addGroup(rows: [
        storageDirectoryRow(),
        numericRow(key: "max_items", title: t("storedItems"), help: t("storedItemsHelp")),
        numericRow(
          key: "max_history_bytes", title: t("historyBudget"),
          help: f(
            "historyBudgetHelp",
            [NativeFormatting.bytes(settings.maxEventBytes, language: settings.language)])),
        numericRow(key: "max_event_bytes", title: t("eventBudget"), help: t("eventBudgetHelp")),
      ])
      heading(t("clipboardHistory"))
      let clear = SettingsButton(
        t(clearing ? "clearingHistory" : "clearAll"), style: .danger, symbol: "trash"
      ) { [weak self] in self?.confirmClear() }
      clear.identifier = NSUserInterfaceItemIdentifier("clear")
      clear.isEnabled = canEdit && controller.stats.totalItems > 0
      controls.append(clear)
      let copy = copyStack(
        title: titleWithHelp(t("clipboardHistory"), help: nil),
        description: f("clearHistoryDescription", [String(controller.stats.totalItems)]))
      addGroup(rows: [makeRow(copy: copy, control: clear, minimum: 54)])
    case .menuBar:
      let shown = optimistic["show_in_menu_bar"].map { $0 == "true" } ?? settings.showInMenuBar
      let toggle = switchRow(
        title: t("showInMenuBar"), value: shown, key: "show_in_menu_bar", compact: true
      ) {
        [weak self] in self?.saveSetting("show_in_menu_bar", value: String($0))
      }
      let count = numericRow(
        key: "menu_bar_item_limit", title: t("menuBarItemLimit"),
        help: f("menuBarItemLimitDescription", [String(settings.menuBarItemLimit)]), compact: true)
      count.toolTip = f("menuBarItemLimitDescription", [String(settings.menuBarItemLimit)])
      addGroup(rows: [toggle, count])
    }
    for control in controls {
      control.isEnabled = control.isEnabled && (control is SettingsThemeButton ? canChooseTheme : canEdit)
    }
    view.layoutSubtreeIfNeeded()
    contentScroll.contentView.scroll(
      to: NSPoint(
        x: 0,
        y: max(0, min(scroll.y, bodyStack.bounds.height - contentScroll.contentView.bounds.height)))
    )
    contentScroll.reflectScrolledClipView(contentScroll.contentView)
  }
  private var canEdit: Bool { !controller.readOnly && !busy }
  private var canChooseTheme: Bool {
    !controller.readOnly && (!busy || themeSaveTask != nil)
  }

  private func addBody(_ child: NSView) {
    bodyStack.addArrangedSubview(child)
    child.widthAnchor.constraint(equalTo: bodyStack.widthAnchor, constant: -40).isActive = true
  }
  private func heading(_ title: String, first: Bool = false) {
    let wrap = NSView()
    let text = label(title, size: 13.5, weight: .semibold)
    text.translatesAutoresizingMaskIntoConstraints = false
    wrap.addSubview(text)
    NSLayoutConstraint.activate([
      text.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 10),
      text.trailingAnchor.constraint(lessThanOrEqualTo: wrap.trailingAnchor, constant: -10),
      text.topAnchor.constraint(equalTo: wrap.topAnchor, constant: first ? 0 : 12),
      text.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
    ])
    addBody(wrap)
  }
  private func addGroup(rows: [NSView]) {
    let group = SettingsSurface()
    group.color = SettingsPalette.surface
    group.stroke = SettingsPalette.groupBorder
    group.radius = 13
    let stack = FlippedStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 0
    stack.translatesAutoresizingMaskIntoConstraints = false
    group.addSubview(stack)
    for (index, row) in rows.enumerated() {
      if index > 0 {
        let lineWrap = NSView()
        let line = SettingsDivider()
        line.translatesAutoresizingMaskIntoConstraints = false
        lineWrap.addSubview(line)
        NSLayoutConstraint.activate([
          lineWrap.heightAnchor.constraint(equalToConstant: 1),
          line.leadingAnchor.constraint(equalTo: lineWrap.leadingAnchor, constant: 10),
          line.trailingAnchor.constraint(equalTo: lineWrap.trailingAnchor, constant: -10),
          line.topAnchor.constraint(equalTo: lineWrap.topAnchor),
          line.bottomAnchor.constraint(equalTo: lineWrap.bottomAnchor),
        ])
        stack.addArrangedSubview(lineWrap)
        lineWrap.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
      }
      stack.addArrangedSubview(row)
      row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: group.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: group.trailingAnchor),
      stack.topAnchor.constraint(equalTo: group.topAnchor),
      stack.bottomAnchor.constraint(equalTo: group.bottomAnchor),
    ])
    addBody(group)
  }
  private func label(
    _ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, secondary: Bool = false,
    color: NSColor? = nil
  ) -> NSTextField {
    let result = SettingsWrappingLabel(text)
    result.font = .systemFont(ofSize: size, weight: weight)
    let textColor = color ?? (secondary ? SettingsPalette.secondary : SettingsPalette.primary)
    result.textColor = textColor
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = size * (secondary ? 1.45 : 1.4)
    paragraph.maximumLineHeight = paragraph.minimumLineHeight
    result.heightAnchor.constraint(greaterThanOrEqualToConstant: paragraph.minimumLineHeight)
      .isActive = true
    result.attributedStringValue = NSAttributedString(
      string: text,
      attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: textColor,
        .paragraphStyle: paragraph,
      ])
    result.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    result.setContentCompressionResistancePriority(.required, for: .vertical)
    return result
  }
  private func titleWithHelp(_ title: String, help: String?) -> NSView {
    let text = label(title)
    guard let help else { return text }
    let button = SettingsButton("", style: .help, symbol: "questionmark.circle") {}
    button.handler = { [weak self, weak button] in
      if let button { self?.toggleHelp(help, anchor: button) }
    }
    button.setAccessibilityLabel(f("settingHelp", [title]))
    button.toolTip = help
    let row = NSStackView(views: [text, button])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 4
    return row
  }
  private func copyStack(
    title: NSView, description: String? = nil, symbol: String? = nil, size: CGFloat = 13
  ) -> NSView {
    let copy = NSStackView(views: [title])
    copy.orientation = .vertical
    copy.alignment = .leading
    copy.spacing = 2
    title.widthAnchor.constraint(equalTo: copy.widthAnchor).isActive = true
    if let description {
      let text = label(description, size: size, secondary: true)
      if let symbol {
        let image = NSImageView(image: OriginalIcons.image(symbol) ?? NSImage())
        image.contentTintColor = SettingsPalette.secondary
        image.widthAnchor.constraint(equalToConstant: 13).isActive = true
        image.heightAnchor.constraint(equalToConstant: 13).isActive = true
        let row = NSStackView(views: [image, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 6
        copy.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: copy.widthAnchor).isActive = true
      } else {
        copy.addArrangedSubview(text)
        text.widthAnchor.constraint(equalTo: copy.widthAnchor).isActive = true
      }
    }
    copy.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    copy.setContentCompressionResistancePriority(.required, for: .vertical)
    return copy
  }
  private func makeRow(copy: NSView, control: NSView, minimum: CGFloat, padding: CGFloat = 10)
    -> NSView
  {
    let row = NSStackView(views: [copy, control])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 12
    row.distribution = .fill
    row.edgeInsets = NSEdgeInsets(top: padding, left: 12, bottom: padding, right: 12)
    NSLayoutConstraint.activate([
      row.heightAnchor.constraint(greaterThanOrEqualToConstant: minimum),
      copy.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: padding),
      copy.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -padding),
      control.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: padding),
      control.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -padding),
    ])
    control.setContentHuggingPriority(.required, for: .horizontal)
    control.setContentCompressionResistancePriority(.required, for: .horizontal)
    copy.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return row
  }
  private func switchRow(
    title: String, description: String? = nil, descriptionSymbol: String? = nil, value: Bool,
    key: String? = nil, compact: Bool = false, action: @escaping @MainActor (Bool) -> Void
  ) -> NSView {
    let toggle = SettingsSwitch(value: value, label: title, handler: action)
    if let key { toggle.identifier = NSUserInterfaceItemIdentifier(key) }
    controls.append(toggle)
    let copy = copyStack(
      title: titleWithHelp(title, help: nil), description: description, symbol: descriptionSymbol)
    let row = SettingsClickableRow(
      content: makeRow(
        copy: copy, control: toggle, minimum: compact ? 46 : 54, padding: compact ? 9 : 10)
    ) { [weak toggle] in toggle?.performClick(nil) }
    return row
  }
  private func languageRow() -> NSView {
    let popup = SettingsPopup { [weak self] sender in
      guard let value = sender.selectedItem?.representedObject as? String else { return }
      self?.saveSetting("language", value: value)
    }
    let languages = [
      ("system", t("systemDefault")), ("en", "English"), ("zh-CN", "简体中文"), ("zh-TW", "繁體中文"),
    ]
    for (value, title) in languages {
      popup.addItem(withTitle: title)
      popup.lastItem?.representedObject = value
    }
    popup.selectItem(
      at: languages.firstIndex { $0.0 == (optimistic["language"] ?? controller.settings.language) }
        ?? 0)
    popup.setAccessibilityLabel(t("language"))
    popup.identifier = NSUserInterfaceItemIdentifier("language")
    controls.append(popup)
    return makeRow(copy: label(t("language")), control: popup, minimum: 46, padding: 9)
  }
  private func range(_ key: String) -> ClosedRange<Int64> {
    switch key {
    case "max_items": 1...1_000
    case "max_history_bytes": 16...4_096
    case "max_event_bytes": 1...256
    default: 0...1_000
    }
  }
  private func validationKey(_ key: String) -> String {
    switch key {
    case "max_items": "storageLimitError"
    case "max_history_bytes": "historyBudgetError"
    case "max_event_bytes": "eventBudgetError"
    default: "menuBarItemLimitError"
    }
  }
  private func number(_ raw: String, key: String) -> Int64? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
      let number = Int64(value), range(key).contains(number)
    else { return nil }
    return number
  }
  private func numericRow(key: String, title: String, help: String?, compact: Bool = false)
    -> NSView
  {
    let input = SettingsNumberInput(
      value: drafts[key] ?? String(savedNumbers[key] ?? 0),
      width: 86, label: title)
    input.field.delegate = self
    input.field.identifier = NSUserInterfaceItemIdentifier(key)
    numericFields[key] = input.field
    controls.append(input.field)
    controls.append(input.stepper)
    input.field.step = { [weak self, weak field = input.field] step in
      guard let self, let field else { return }
      let old = Int64(field.stringValue) ?? self.savedNumbers[key] ?? self.range(key).lowerBound
      field.stringValue = String(
        min(self.range(key).upperBound, max(self.range(key).lowerBound, old + Int64(step))))
      self.drafts[key] = field.stringValue
      self.updateValidation(key)
    }
    let apply = SettingsButton(t("apply"), style: .primary) { [weak self] in self?.applyNumber(key)
    }
    apply.identifier = NSUserInterfaceItemIdentifier(key + ".apply")
    numericButtons[key] = apply
    controls.append(apply)
    var items: [NSView] = [input]
    var controlsWidth: CGFloat = 86 + apply.intrinsicContentSize.width + 6
    if key == "max_event_bytes" || key == "max_history_bytes" {
      let unit = label("MiB", secondary: true)
      let unitWidth =
        ceil(("MiB" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width)
        + 4
      unit.widthAnchor.constraint(equalToConstant: unitWidth).isActive = true
      items.append(unit)
      controlsWidth += unitWidth + 6
    }
    items.append(apply)
    let controlsRow = NSStackView(views: items)
    controlsRow.orientation = .horizontal
    controlsRow.alignment = .centerY
    controlsRow.spacing = 6
    controlsRow.widthAnchor.constraint(equalToConstant: controlsWidth).isActive = true
    let row = makeRow(
      copy: titleWithHelp(title, help: help), control: controlsRow, minimum: compact ? 46 : 54,
      padding: compact ? 9 : 10)
    let error = label(t(validationKey(key)), color: SettingsPalette.danger)
    let errorWrap = NSStackView(views: [error])
    errorWrap.orientation = .vertical
    errorWrap.alignment = .leading
    errorWrap.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 10, right: 12)
    numericErrors[key] = error
    numericErrorRows[key] = errorWrap
    let full = FlippedStackView()
    full.orientation = .vertical
    full.alignment = .leading
    full.spacing = 0
    full.addArrangedSubview(row)
    full.addArrangedSubview(errorWrap)
    row.widthAnchor.constraint(equalTo: full.widthAnchor).isActive = true
    errorWrap.widthAnchor.constraint(equalTo: full.widthAnchor).isActive = true
    error.widthAnchor.constraint(equalTo: full.widthAnchor, constant: -24).isActive = true
    updateValidation(key)
    return full
  }
  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? SettingsNumberField,
      let key = field.identifier?.rawValue
    else { return }
    drafts[key] = field.stringValue
    updateValidation(key)
  }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
    -> Bool
  {
    guard let field = control as? SettingsNumberField else { return false }
    if commandSelector == #selector(NSResponder.moveUp(_:)) {
      field.step?(1)
      return true
    }
    if commandSelector == #selector(NSResponder.moveDown(_:)) {
      field.step?(-1)
      return true
    }
    return false
  }
  private func updateValidation(_ key: String) {
    let value = numericFields[key]?.stringValue ?? drafts[key] ?? ""
    let number = number(value, key: key)
    numericErrorRows[key]?.isHidden = number != nil
    numericButtons[key]?.isEnabled = canEdit && number != nil && number != savedNumbers[key]
  }
  private func applyNumber(_ key: String) {
    guard canEdit, let raw = numericFields[key]?.stringValue, let value = number(raw, key: key),
      value != savedNumbers[key]
    else { return }
    if key == "max_items", value < controller.stats.totalItems {
      let message =
        f(
          "reduceHistoryDescription",
          [
            String(controller.settings.maxItems), String(value),
            String(max(0, controller.stats.totalItems - value)),
          ]) + "\n\n" + t("cannotUndo")
      guard
        controller.confirm(
          title: t("reduceHistory"), message: message, confirmLabel: t("deleteAndUpdate"))
      else {
        drafts[key] = String(savedNumbers[key] ?? value)
        numericFields[key]?.stringValue = drafts[key] ?? ""
        updateValidation(key)
        restoreFocus(key: key)
        return
      }
    }
    drafts[key] = raw
    saveSetting(
      key,
      value: String(
        value * (key == "max_history_bytes" || key == "max_event_bytes" ? 1_048_576 : 1)))
  }
  /// Isolated regression tests wait for persistence without a timing guess.
  func diagnosticWaitForThemeSave() async { await themeSaveTask?.value }

  private func saveTheme(_ value: String) {
    guard canChooseTheme else { return }
    saveDrafts()
    closeHelp()
    pendingTheme = value
    optimistic["theme"] = value
    showError("")
    updateThemeSelection(value)
    controller.previewTheme(value)
    guard themeSaveTask == nil else { return }
    busy = true
    themeSaveTask = Task { [weak self] in
      guard let self else { return }
      var lastValue = value
      while let next = self.pendingTheme {
        self.pendingTheme = nil
        lastValue = next
        let succeeded = await self.controller.updateSettingAsync("theme", value: next)
        // A newer click owns the visible appearance and error state.
        guard self.pendingTheme == nil else { continue }
        if succeeded {
          self.retryAction = nil
          self.showError("")
        } else {
          self.retryAction = { [weak self] in self?.saveTheme(next) }
          if self.errorMessage.isEmpty { self.showError(self.t("error.update_settings")) }
        }
      }
      self.optimistic.removeValue(forKey: "theme")
      self.controller.previewTheme(nil)
      self.busy = false
      self.themeSaveTask = nil
      self.rebuildError()
      if self.category == .appearance {
        self.updateThemeSelection(self.controller.settings.theme)
        self.restoreFocus(key: "theme", value: lastValue)
      } else {
        self.reload()
      }
    }
  }

  /// Updating the existing radio controls keeps focus, layout, and the window
  /// intact throughout a rapid sequence of theme selections.
  private func updateThemeSelection(_ value: String) {
    for case let button as SettingsThemeButton in controls {
      button.chosen = button.theme == value
      button.isEnabled = !controller.readOnly
    }
  }

  private func saveSetting(_ key: String, value: String) {
    if key == "theme" { saveTheme(value); return }
    guard canEdit else { return }
    saveDrafts()
    closeHelp()
    busy = true
    optimistic[key] = value
    showError("")
    retryAction = { [weak self] in self?.saveSetting(key, value: value) }
    rebuildCategory()
    Task { [weak self] in
      guard let self else { return }
      let succeeded = await self.controller.updateSettingAsync(key, value: value)
      self.busy = false
      self.optimistic.removeValue(forKey: key)
      if succeeded {
        self.retryAction = nil
        self.showError("")
      } else if self.errorMessage.isEmpty {
        self.showError(self.t("error.update_settings"))
      }
      self.reload()
      self.restoreFocus(key: key, value: value)
    }
  }
  private func storageDirectoryRow() -> NSView {
    let path = controller.storageURL.deletingLastPathComponent().path
    let text = label(path, size: 12, secondary: true)
    text.isSelectable = true
    text.setAccessibilityLabel(t("storageDirectory") + ": " + path)
    let copy = NSStackView(views: [
      titleWithHelp(t("storageDirectory"), help: t("storageDirectoryHelp")), text,
    ])
    copy.orientation = .vertical
    copy.alignment = .leading
    copy.spacing = 2
    text.widthAnchor.constraint(equalTo: copy.widthAnchor).isActive = true
    if moving { copy.addArrangedSubview(label(t("movingStorage"), size: 12, secondary: true)) }
    let change = SettingsButton(t("changeStorageDirectory")) { [weak self] in
      self?.chooseDirectory()
    }
    change.identifier = NSUserInterfaceItemIdentifier("storage")
    controls.append(change)
    return makeRow(copy: copy, control: change, minimum: 54)
  }
  private func chooseDirectory() {
    guard canEdit, let window = view.window else { return }
    closeHelp()
    let panel = NSOpenPanel()
    panel.title = t("chooseDirectory")
    panel.prompt = t("changeStorageDirectory")
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = controller.storageURL.deletingLastPathComponent()
    panel.beginSheetModal(for: window) { [weak self] response in
      if response == .OK, let url = panel.url { self?.moveStorage(url) }
    }
  }
  private func moveStorage(_ destination: URL) {
    guard canEdit else { return }
    saveDrafts()
    busy = true
    moving = true
    showError("")
    retryAction = { [weak self] in self?.moveStorage(destination) }
    rebuildCategory()
    Task { [weak self] in
      guard let self else { return }
      let success = await self.controller.moveStorageAsync(to: destination)
      self.busy = false
      self.moving = false
      if success {
        self.retryAction = nil
        self.showError("")
      } else if self.errorMessage.isEmpty {
        self.showError(self.t("error.move_storage"))
      }
      self.reload()
      if !success {
        self.contentScroll.contentView.scroll(to: .zero)
        self.contentScroll.reflectScrolledClipView(self.contentScroll.contentView)
      }
      self.restoreFocus(key: "storage")
    }
  }
  private func confirmClear() {
    guard canEdit, controller.stats.totalItems > 0 else { return }
    closeHelp()
    let message =
      f("clearHistoryConfirmationDescription", [String(controller.stats.totalItems)]) + "\n\n"
      + t("cannotUndo")
    guard
      controller.confirm(
        title: t("clearHistoryConfirmationTitle"), message: message, confirmLabel: t("clearAll"))
    else { return }
    clearUnpinned()
  }
  private func clearUnpinned() {
    guard canEdit else { return }
    saveDrafts()
    busy = true
    clearing = true
    showError("")
    retryAction = { [weak self] in self?.clearUnpinned() }
    rebuildCategory()
    Task { [weak self] in
      guard let self else { return }
      let success = await self.controller.clearHistoryAsync(includePinned: false)
      self.busy = false
      self.clearing = false
      if success {
        self.retryAction = nil
        self.showError("")
      } else if self.errorMessage.isEmpty {
        self.showError(self.t("error.clear_history"))
      }
      self.reload()
      self.restoreFocus(key: "clear")
    }
  }
  private func restoreFocus(key: String, value: String? = nil) {
    guard view.window?.contentViewController === self else { return }
    if let field = numericFields[key] {
      let button = numericButtons[key]
      view.window?.makeFirstResponder(button?.isEnabled == true ? button : field)
      return
    }
    let identifier = key == "theme" ? "theme:" + (value ?? controller.settings.theme) : key
    if let target = controls.first(where: { $0.identifier?.rawValue == identifier && $0.isEnabled })
    {
      view.window?.makeFirstResponder(target)
    } else if controls.contains(where: { $0.identifier?.rawValue == identifier }) {
      view.window?.makeFirstResponder(contentScroll)
    }
  }
  private func rebuildError() {
    for child in errorHost.arrangedSubviews {
      errorHost.removeArrangedSubview(child)
      child.removeFromSuperview()
    }
    errorHost.isHidden = errorMessage.isEmpty
    guard !errorMessage.isEmpty else { return }
    let surface = SettingsSurface()
    surface.color = SettingsPalette.dangerFill
    surface.stroke = SettingsPalette.separator
    surface.radius = 12
    let warning = NSImageView(image: OriginalIcons.image("exclamationmark.triangle") ?? NSImage())
    warning.contentTintColor = SettingsPalette.danger
    warning.widthAnchor.constraint(equalToConstant: 16).isActive = true
    warning.heightAnchor.constraint(equalToConstant: 16).isActive = true
    let text = label(errorMessage, color: SettingsPalette.danger)
    var children: [NSView] = [warning, text]
    if retryAction != nil {
      let retry = SettingsButton(t("retry")) { [weak self] in self?.retryAction?() }
      retry.isEnabled = !busy
      children.append(retry)
    }
    let dismiss = SettingsButton("", style: .dismiss, symbol: "xmark") { [weak self] in
      self?.showError("")
    }
    dismiss.setAccessibilityLabel(t("dismiss"))
    dismiss.toolTip = t("dismiss")
    children.append(dismiss)
    let row = NSStackView(views: children)
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    row.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 10)
    row.translatesAutoresizingMaskIntoConstraints = false
    surface.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
      row.topAnchor.constraint(equalTo: surface.topAnchor),
      row.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
    ])
    errorHost.addArrangedSubview(surface)
    surface.widthAnchor.constraint(equalTo: errorHost.widthAnchor).isActive = true
    errorHost.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 0)
  }
  private func helpRow(for anchor: NSButton) -> NSView {
    var current: NSView? = anchor.superview
    while let candidate = current {
      if let row = candidate as? NSStackView, row.orientation == .horizontal,
        row.edgeInsets.left == 12
      {
        return row
      }
      current = candidate.superview
    }
    return anchor
  }
  private func toggleHelp(_ message: String, anchor: NSButton) {
    if helpAnchor === anchor, helpBubble != nil {
      closeHelp()
      return
    }
    closeHelp()
    let row = helpRow(for: anchor)
    let width = max(220, row.bounds.width - 20)
    let bubble = SettingsHelpBubble(message: message, width: width)
    helpBubble = bubble
    helpAnchor = anchor
    anchor.setAccessibilityExpanded(true)
    (anchor as? SettingsButton)?.expanded = true
    view.addSubview(bubble)
    positionHelp()
    helpObservation = SettingsHelpObservation(
      window: view.window, clip: contentScroll.contentView,
      event: { [weak self, weak anchor] event in
        guard let self, let bubble = self.helpBubble else { return event }
        if event.type == .keyDown, event.keyCode == 53 {
          self.closeHelp()
          if let anchor { self.view.window?.makeFirstResponder(anchor) }
          return nil
        }
        guard event.type != .keyDown else { return event }
        if event.window !== self.view.window {
          self.closeHelp()
          return event
        }
        let point = self.view.convert(event.locationInWindow, from: nil)
        let anchorRect = anchor.map { $0.convert($0.bounds, to: self.view) } ?? .zero
        if !bubble.frame.contains(point), !anchorRect.contains(point) { self.closeHelp() }
        return event
      }, layout: { [weak self] in self?.positionHelp() },
      deactivate: { [weak self] in self?.closeHelp() })
  }
  private func positionHelp() {
    guard let anchor = helpAnchor, let bubble = helpBubble else { return }
    let row = helpRow(for: anchor)
    let rect = row.convert(row.bounds, to: view)
    bubble.frame.origin = NSPoint(x: rect.minX + 10, y: rect.maxY + 6)
  }
  private func closeHelp() {
    helpAnchor?.setAccessibilityExpanded(false)
    (helpAnchor as? SettingsButton)?.expanded = false
    helpBubble?.removeFromSuperview()
    helpBubble = nil
    helpAnchor = nil
    helpObservation = nil
  }

}

@MainActor
private final class SettingsClickableRow: NSView {
  let handler: @MainActor () -> Void
  init(content: NSView, handler: @escaping @MainActor () -> Void) {
    self.handler = handler
    super.init(frame: .zero)
    content.translatesAutoresizingMaskIntoConstraints = false
    addSubview(content)
    NSLayoutConstraint.activate([
      content.topAnchor.constraint(equalTo: topAnchor),
      content.bottomAnchor.constraint(equalTo: bottomAnchor),
      content.leadingAnchor.constraint(equalTo: leadingAnchor),
      content.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])
  }
  required init?(coder: NSCoder) { nil }
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    if let text = hit as? NSTextField, !text.isEditable, !text.isSelectable { return self }
    if hit is NSImageView { return self }
    return hit
  }
  override func mouseDown(with event: NSEvent) { handler() }
}

/// Observer tokens are removed independently of the main-actor controller lifecycle.
private final class SettingsWindowObservation: @unchecked Sendable {
  let tokens: [NSObjectProtocol]
  @MainActor init(window: NSWindow?, update: @escaping @MainActor () -> Void) {
    tokens = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
      NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
        Task { @MainActor in update() }
      }
    }
  }
  deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
}

/// Local event monitors preserve the original same-window help interaction.
@MainActor
private final class SettingsHelpObservation {
  private var monitor: Any?
  private var tokens: [NSObjectProtocol] = []
  init(
    window: NSWindow?, clip: NSClipView,
    event: @escaping @MainActor (NSEvent) -> NSEvent?,
    layout: @escaping @MainActor () -> Void,
    deactivate: @escaping @MainActor () -> Void
  ) {
    monitor = NSEvent.addLocalMonitorForEvents(matching: [
      .leftMouseDown, .rightMouseDown, .keyDown,
    ]) { value in
      let forward = MainActor.assumeIsolated { event(value) != nil }
      return forward ? value : nil
    }
    clip.postsBoundsChangedNotifications = true
    tokens.append(
      NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
      ) { _ in
        MainActor.assumeIsolated { layout() }
      })
    tokens.append(
      NotificationCenter.default.addObserver(
        forName: NSWindow.didResignKeyNotification, object: window, queue: .main
      ) { _ in
        MainActor.assumeIsolated { deactivate() }
      })
  }
  isolated deinit {
    if let monitor { NSEvent.removeMonitor(monitor) }
    for token in tokens { NotificationCenter.default.removeObserver(token) }
  }
}
