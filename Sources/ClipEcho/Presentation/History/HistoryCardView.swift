import AppKit
import ClipEchoCore

@MainActor
enum HistoryVisual {
  static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
    NSImage(size: image.size, flipped: false) { rect in
      image.draw(in: rect)
      color.setFill()
      rect.fill(using: .sourceAtop)
      return true
    }
  }
  static func color(_ light: UInt32, _ dark: UInt32, in view: NSView) -> NSColor {
    let value =
      view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    return NSColor(
      srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
      blue: CGFloat(value & 255) / 255, alpha: 1)
  }
  static func canvas(_ view: NSView) -> NSColor { color(0xf3f3f5, 0x202023, in: view) }
  static func surface(_ view: NSView) -> NSColor { color(0xffffff, 0x2b2b2f, in: view) }
  static func text(_ view: NSView) -> NSColor { color(0x202124, 0xf0f0f2, in: view) }
  static func secondary(_ view: NSView) -> NSColor { color(0x65676d, 0xb1b1b9, in: view) }
  static func tertiary(_ view: NSView) -> NSColor { color(0x777a81, 0x97979f, in: view) }
  static func accent(_ view: NSView) -> NSColor { color(0x0068df, 0x1870d8, in: view) }
  static func controlFill(_ view: NSView) -> NSColor {
    color(0x787880, 0xb4b4be, in: view).withAlphaComponent(isDark(view) ? 0.12 : 0.1)
  }
  static func controlBorder(_ view: NSView) -> NSColor {
    (isDark(view) ? NSColor.white : color(0x3c3c43, 0xffffff, in: view))
      .withAlphaComponent(isDark(view) ? 0.18 : 0.19)
  }
  static func accentFill(_ view: NSView) -> NSColor {
    color(0x0068df, 0x4696ff, in: view).withAlphaComponent(isDark(view) ? 0.16 : 0.09)
  }
  static func pinForeground(_ view: NSView) -> NSColor { color(0x0068df, 0x80b8ff, in: view) }
  static func danger(_ view: NSView) -> NSColor { color(0xc32627, 0xff827a, in: view) }
  static func dangerFill(_ view: NSView) -> NSColor {
    color(0xc32627, 0xff6464, in: view).withAlphaComponent(isDark(view) ? 0.1 : 0.08)
  }
  static func focusRing(_ view: NSView) -> NSColor {
    color(0x0068df, 0x50a0ff, in: view).withAlphaComponent(isDark(view) ? 0.38 : 0.3)
  }
  static func isDark(_ view: NSView) -> Bool {
    view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
  }
  static func separator(_ view: NSView) -> NSColor {
    (view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      ? NSColor.white : NSColor(srgbRed: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: 1))
      .withAlphaComponent(
        view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.09 : 0.12)
  }
  static func textHeight(_ text: String, width: CGFloat, font: NSFont, lineHeight: CGFloat)
    -> CGFloat
  {
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = lineHeight
    paragraph.maximumLineHeight = lineHeight
    paragraph.lineBreakMode = .byCharWrapping
    return max(
      lineHeight,
      (text as NSString).boundingRect(
        with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: font, .paragraphStyle: paragraph]
      ).height)
  }
  private static func scalarWidth(_ scalar: UnicodeScalar) -> Int {
    let c = scalar.value
    return (0x1100...0x115f).contains(c) || [0x2329, 0x232a].contains(c)
      || (0x2e80...0xa4cf).contains(c) || (0xac00...0xd7a3).contains(c)
      || (0xf900...0xfaff).contains(c) || (0xfe10...0xfe19).contains(c)
      || (0xfe30...0xfe6f).contains(c) || (0xff00...0xff60).contains(c)
      || (0xffe0...0xffe6).contains(c) || (0x1f300...0x1faff).contains(c) ? 2 : 1
  }
  static func displayWidth(_ value: String) -> Int {
    value.unicodeScalars.reduce(0) { $0 + scalarWidth($1) }
  }
  static func truncate(_ value: String, width: Int = 40) -> String {
    let value = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard displayWidth(value) > width else { return value }
    var result = ""
    var used = 0
    for scalar in value.unicodeScalars {
      let next = scalarWidth(scalar)
      if used + next > max(0, width - 3) { break }
      result.unicodeScalars.append(scalar)
      used += next
    }
    return result + "..."
  }
  static func timestamp(_ milliseconds: Int64, language: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: L10n.resolve(language))
    formatter.setLocalizedDateFormatFromTemplate("yyyyMdjmmss")
    return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
  }
}

@MainActor
class HistoryLabel: NSTextField {
  let cssLineHeight: CGFloat
  var kerning: CGFloat = 0
  init(
    _ text: String = "", size: CGFloat = 13.44, weight: NSFont.Weight = .regular,
    lineHeight: CGFloat? = nil, singleLine: Bool = false
  ) {
    cssLineHeight = lineHeight ?? size * 1.5
    super.init(frame: .zero)
    stringValue = text
    isBordered = false
    isBezeled = false
    drawsBackground = false
    isEditable = false
    isSelectable = false
    font = .systemFont(ofSize: size, weight: weight)
    lineBreakMode = .byCharWrapping
    maximumNumberOfLines = singleLine ? 1 : 0
  }
  required init?(coder: NSCoder) { nil }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  private var drawingAttributes: [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = maximumNumberOfLines == 1 ? .byClipping : .byCharWrapping
    paragraph.minimumLineHeight = cssLineHeight
    paragraph.maximumLineHeight = cssLineHeight
    return [
      .font: font ?? .systemFont(ofSize: 13.44),
      .foregroundColor: textColor ?? NSColor.labelColor, .paragraphStyle: paragraph, .kern: kerning,
    ]
  }
  var textWidth: CGFloat {
    ceil((stringValue as NSString).size(withAttributes: drawingAttributes).width)
  }
  /// Draw exactly in the CSS content box. NSTextFieldCell adds a private text
  /// inset even after title/drawing rectangle overrides on current macOS.
  override func draw(_ dirtyRect: NSRect) {
    var rect = bounds
    if maximumNumberOfLines == 1 {
      rect.origin.y += max(0, (rect.height - cssLineHeight) / 2)
    }
    (stringValue as NSString).draw(
      with: rect,
      options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: drawingAttributes)
  }
}

@MainActor
final class HistoryActionButton: NSButton {
  enum Style { case plain, primary, success, pinned, danger, secondary }
  var visualStyle: Style = .plain { didSet { needsDisplay = true } }
  var onClick: (() -> Void)?
  private var hovered = false
  init(symbol: String? = nil, title: String = "", label: String, style: Style = .plain) {
    super.init(frame: .zero)
    self.title = title
    visualStyle = style
    isBordered = false
    bezelStyle = .regularSquare
    focusRingType = .exterior
    if let symbol {
      image = OriginalIcons.image(symbol)
      imagePosition = .imageOnly
    }
    font = .systemFont(ofSize: 12.8, weight: .medium)
    target = self
    action = #selector(clicked)
    toolTip = label
    setAccessibilityLabel(label)
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    addTrackingArea(
      NSTrackingArea(
        rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
        owner: self))
  }
  override func mouseEntered(with event: NSEvent) {
    hovered = true
    needsDisplay = true
  }
  override func mouseExited(with event: NSEvent) {
    hovered = false
    needsDisplay = true
  }
  override func draw(_ dirtyRect: NSRect) {
    var fill = NSColor.clear
    var ink = HistoryVisual.secondary(self)
    switch visualStyle {
    case .primary:
      fill = HistoryVisual.accent(self)
      ink = .white
    case .success:
      fill = NSColor(srgbRed: 36 / 255, green: 132 / 255, blue: 62 / 255, alpha: 1)
      ink = .white
    case .pinned:
      fill = HistoryVisual.accentFill(self)
      ink = HistoryVisual.pinForeground(self)
    case .secondary:
      fill = HistoryVisual.controlFill(self)
      ink = HistoryVisual.text(self)
    case .danger:
      if hovered {
        fill = HistoryVisual.dangerFill(self)
        ink = HistoryVisual.danger(self)
      }
    case .plain:
      if hovered {
        fill = HistoryVisual.controlFill(self)
        ink = HistoryVisual.text(self)
      }
    }
    if !isEnabled {
      ink = ink.withAlphaComponent(0.45)
      fill = fill.withAlphaComponent(0.45)
    }
    fill.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    if let image {
      let tinted = HistoryVisual.tinted(image, color: ink)
      tinted.draw(
        in: NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16),
        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    } else {
      let attributes: [NSAttributedString.Key: Any] = [
        .font: font ?? .systemFont(ofSize: 12.8), .foregroundColor: ink,
      ]
      let size = (title as NSString).size(withAttributes: attributes)
      (title as NSString).draw(
        at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
        withAttributes: attributes)
    }
  }
  @objc private func clicked() { onClick?() }
}

@MainActor
private final class HistoryBadge: NSView {
  private let label: HistoryLabel
  private let accent: Bool
  private let pin: Bool
  override var isFlipped: Bool { true }
  init(_ value: String, accent: Bool = false, pin: Bool = false) {
    self.accent = accent
    self.pin = pin
    label = HistoryLabel(value, size: 9.92, weight: .medium, lineHeight: 11.408, singleLine: true)
    super.init(frame: .zero)
    addSubview(label)
  }
  required init?(coder: NSCoder) { nil }
  var desiredWidth: CGFloat {
    label.textWidth + 12
      + (pin ? 15 : 0)
  }
  override func layout() {
    super.layout()
    label.frame = NSRect(
      x: pin ? 21 : 6, y: 3, width: max(0, bounds.width - 12 - (pin ? 15 : 0)), height: 12)
  }
  override func draw(_ rect: NSRect) {
    (accent
      ? HistoryVisual.accentFill(self)
      : HistoryVisual.controlFill(self)).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    label.textColor = accent ? HistoryVisual.pinForeground(self) : HistoryVisual.secondary(self)
    if pin {
      if let image = OriginalIcons.image("pin") {
        HistoryVisual.tinted(image, color: HistoryVisual.pinForeground(self)).draw(
          in: NSRect(x: 6, y: 3, width: 12, height: 12), from: .zero, operation: .sourceOver,
          fraction: 1, respectFlipped: true, hints: nil)
      }
    }
  }
}

@MainActor
final class HistoryCardView: NSView {
  let item: HistoryItem
  var onToggle: (() -> Void)?
  var onRestore: (() -> Void)?
  var onPin: (() -> Void)?
  var onDelete: (() -> Void)?
  var onRetry: (() -> Void)?
  var expanded = false
  var copied = false
  var restoring = false
  var pinning = false
  var deleting = false
  var detailState = 0  // 0: summary, 1: loading, 2: failure, 3: loaded
  var detail: InlineHistoryDetail?
  var onHeightChanged: (() -> Void)?
  private let language: String
  private let query: String
  private var badges: [HistoryBadge] = []
  private let previewLabel = HistoryLabel()
  private let typeIcon = NSImageView()
  private let timestamp = HistoryLabel(size: 10.88, lineHeight: 15.232, singleLine: true)
  private let searchMatch = HistoryLabel(size: 13.12, lineHeight: 19.02)
  private let searchIcon = NSImageView()
  private let status = HistoryLabel(size: 12.16)
  private let retryButton = HistoryActionButton(title: "", label: "")
  private let pinButton: HistoryActionButton
  private let restoreButton: HistoryActionButton
  private let deleteButton: HistoryActionButton
  private var preview: HistoryInlinePreviewView?
  private var previewIsSummary = false
  private var hovered = false
  private var previousCopied = false
  private var focusFromMouse = false
  private var keyboardFocusVisible = false
  private var showsLoading: Bool {
    detailState == 1 || (detailState == 3 && preview?.isReady == false)
  }
  private var showsStatus: Bool { expanded && (showsLoading || detailState == 2) }
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  init(item: HistoryItem, language: String, query: String) {
    self.item = item
    self.language = language
    self.query = query
    pinButton = HistoryActionButton(
      symbol: item.isPinned ? "pin.slash" : "pin",
      label: L10n.string(item.isPinned ? "unpinItem" : "pinItem", language: language),
      style: item.isPinned ? .pinned : .plain)
    restoreButton = HistoryActionButton(
      symbol: "doc.on.doc", label: L10n.string("restoreToClipboard", language: language),
      style: .primary)
    deleteButton = HistoryActionButton(
      symbol: "trash", label: L10n.string("deleteItem", language: language), style: .danger)
    super.init(frame: .zero)
    setAccessibilityRole(.group)
    wantsLayer = true
    layer?.cornerRadius = 12
    layer?.borderWidth = 1
    for child in [
      previewLabel, typeIcon, timestamp, searchMatch, searchIcon, status, retryButton, pinButton,
      restoreButton,
      deleteButton,
    ] { addSubview(child) }
    let imageTypes = ["png", "jpg", "jpeg", "gif", "webp", "tiff", "tif", "bmp", "heic", "heif"]
    let iconName =
      imageTypes.contains(item.dataType)
      ? "photo"
      : ["files", "files and folders"].contains(item.dataType)
        ? "doc.on.doc.fill"
        : item.dataType.contains("folder")
          ? "folder"
          : item.dataType == "file"
            ? "doc"
            : item.dataType == "video"
              ? "video" : item.dataType == "unsupported" ? "exclamationmark.triangle" : nil
    typeIcon.image = iconName.flatMap {
      OriginalIcons.image($0)
    }
    if let first = EventClassifier.parseFileDisplay(item.display)?.items.first {
      typeIcon.image = OriginalIcons.image(first.type == "folder" ? "folder" : "doc")
    }
    searchIcon.image = OriginalIcons.image("magnifyingglass")
    pinButton.onClick = { [weak self] in self?.onPin?() }
    restoreButton.onClick = { [weak self] in self?.onRestore?() }
    deleteButton.onClick = { [weak self] in self?.onDelete?() }
    retryButton.onClick = { [weak self] in self?.onRetry?() }
    retryButton.title = t("retry")
    retryButton.visualStyle = .secondary
    timestamp.stringValue = HistoryVisual.timestamp(item.timestamp, language: language)
    refresh()
  }
  required init?(coder: NSCoder) { nil }
  private func t(_ key: String) -> String { L10n.string(key, language: language) }
  func matches(item: HistoryItem, language: String, query: String) -> Bool {
    self.item == item && self.language == language && self.query == query
  }
  var diagnosticPreviewIdentity: ObjectIdentifier? { preview.map(ObjectIdentifier.init) }
  var diagnosticPreviewIsReady: Bool { preview?.isReady ?? false }
  var diagnosticRetryIsVisible: Bool { !retryButton.isHidden }
  func diagnosticSimulateHTMLProcessTermination() {
    preview?.diagnosticSimulateHTMLProcessTermination()
  }
  func diagnosticHTMLSnapshot() async throws -> HistoryHTMLPreviewView.DiagnosticSnapshot? {
    try await preview?.diagnosticHTMLSnapshot()
  }
  private var summary: String {
    if let files = EventClassifier.parseFileDisplay(item.display), let first = files.items.first {
      let suffix =
        files.items.count > 1
        ? L10n.format("moreItems", language: language, args: [String(files.items.count - 1)]) : ""
      let name =
        first.name.isEmpty
        ? L10n.format(
          first.type == "folder" ? "folderFallbackName" : "fileFallbackName", language: language,
          args: ["1"])
        : first.name
      return HistoryVisual.truncate(name, width: max(0, 40 - HistoryVisual.displayWidth(suffix)))
        + suffix
    }
    guard let value = String(data: item.display, encoding: .utf8) else {
      return L10n.eventType(item.dataType, language: language)
    }
    return item.dataType == "video" && value == "Video" ? t("video") : value
  }
  func clearDetail() {
    detail = nil
    detailState = 0
    preview?.removeFromSuperview()
    preview = nil
    previewIsSummary = false
    refresh()
  }
  func refresh() {
    // A history refresh may restore the decoded cache state; the failed WebKit
    // instance remains unavailable until Retry explicitly discards it.
    if detailState == 3, preview?.hasFailed == true { detailState = 2 }
    for badge in badges { badge.removeFromSuperview() }
    badges = []
    let type =
      (expanded ? detail?.richLabel(language: language) : nil)
      ?? L10n.eventType(item.dataType, language: language)
    badges.append(HistoryBadge(type))
    if item.isPinned { badges.append(HistoryBadge(t("pinned"), accent: true, pin: true)) }
    if item.isRemoteClipboard { badges.append(HistoryBadge(t("remoteClipboard"))) }
    if item.displayTruncated { badges.append(HistoryBadge(t("previewTruncated"))) }
    for badge in badges { addSubview(badge) }
    previewLabel.stringValue = expanded ? summary : HistoryVisual.truncate(summary)
    searchMatch.stringValue = item.searchPreview ?? ""
    let showMatch =
      !expanded && !query.isEmpty
      && !(HistoryVisual.truncate(summary).localizedLowercase.contains(query.localizedLowercase))
      && !(item.searchPreview ?? "").isEmpty
    searchMatch.isHidden = !showMatch
    searchIcon.isHidden = !showMatch
    searchMatch.setAccessibilityLabel(t("searchMatch") + ": " + searchMatch.stringValue)
    if expanded, detailState == 3, let detail {
      if preview == nil || previewIsSummary {
        preview?.removeFromSuperview()
        let child = HistoryInlinePreviewView(detail: detail, language: language)
        child.onHeightChanged = { [weak self] in
          guard let self else { return }
          refresh()
          onHeightChanged?()
        }
        child.onFailure = { [weak self, weak child] in
          guard let self, let child, preview === child else { return }
          detailState = 2
          refresh()
          onHeightChanged?()
        }
        preview = child
        previewIsSummary = false
        addSubview(child)
      }
      preview?.isHidden = preview?.isReady == false
      previewLabel.isHidden = true
    } else if expanded, detailState == 0,
      let files = EventClassifier.parseFileDisplay(item.display)?.items, !files.isEmpty
    {
      if preview == nil || !previewIsSummary {
        preview?.removeFromSuperview()
        let summary = InlineHistoryDetail(
          html: nil, textFallback: nil,
          files: files.map {
            InlineHistoryDetail.FileItem(type: $0.type, name: $0.name, url: nil)
          }, segments: [])
        preview = HistoryInlinePreviewView(detail: summary, language: language)
        previewIsSummary = true
        addSubview(preview!)
      }
      preview?.isHidden = false
      previewLabel.isHidden = true
    } else {
      preview?.isHidden = true
      previewLabel.isHidden = showsStatus
    }
    status.isHidden = !showsStatus
    status.stringValue = t(showsLoading ? "loadingDetail" : "detailUnavailable")
    retryButton.isHidden = !(expanded && detailState == 2)
    pinButton.isEnabled = !pinning && !deleting
    pinButton.state = item.isPinned ? .on : .off
    deleteButton.isEnabled = !pinning && !deleting
    deleteButton.setAccessibilityLabel(t(deleting ? "deletingItem" : "deleteItem"))
    restoreButton.isEnabled = !restoring && !deleting
    restoreButton.image = OriginalIcons.image(copied ? "checkmark" : "doc.on.doc")
    restoreButton.visualStyle = copied ? .success : .primary
    restoreButton.toolTip = t(
      copied ? "copiedToClipboard" : restoring ? "restoringToClipboard" : "restoreToClipboard")
    restoreButton.setAccessibilityLabel(restoreButton.toolTip)
    layer?.backgroundColor =
      (hovered ? HistoryVisual.color(0xfafbfc, 0x303035, in: self) : HistoryVisual.surface(self))
      .cgColor
    layer?.borderColor =
      (hovered || expanded
      ? HistoryVisual.controlBorder(self) : HistoryVisual.separator(self))
      .cgColor
    if copied && !previousCopied, let baseColor = layer?.borderColor {
      let pulse = CAKeyframeAnimation(keyPath: "borderColor")
      pulse.values = [baseColor, HistoryVisual.accent(self).cgColor, baseColor]
      pulse.keyTimes = [0, 0.35, 1]
      pulse.duration = 0.9
      pulse.timingFunctions = [.init(name: .easeOut), .init(name: .easeOut)]
      layer?.add(pulse, forKey: "copyFeedback")
    }
    previousCopied = copied
    previewLabel.textColor = HistoryVisual.text(self)
    typeIcon.contentTintColor = HistoryVisual.secondary(self)
    typeIcon.isHidden = previewLabel.isHidden || typeIcon.image == nil
    timestamp.textColor = HistoryVisual.tertiary(self)
    searchMatch.textColor = HistoryVisual.text(self)
    searchIcon.contentTintColor = HistoryVisual.accent(self)
    status.textColor = HistoryVisual.secondary(self)
    setAccessibilityLabel(summary)
    setAccessibilityExpanded(expanded)
    needsLayout = true
    needsDisplay = true
  }
  func desiredHeight(width: CGFloat) -> CGFloat {
    let contentWidth = max(1, width - 28 - 98 - 12)
    var metaHeight: CGFloat = 17.408
    var x: CGFloat = 0
    for badge in badges {
      if x + badge.desiredWidth > contentWidth && x > 0 {
        metaHeight += 22.408
        x = 0
      }
      x += badge.desiredWidth + 5
    }
    let contentHeight: CGFloat
    if expanded && previewLabel.isHidden, !showsStatus, let preview {
      contentHeight = preview.desiredHeight(width: contentWidth)
    } else if showsStatus {
      contentHeight = showsLoading ? 20 : 32
    } else {
      contentHeight = HistoryVisual.textHeight(
        previewLabel.stringValue, width: contentWidth - (typeIcon.isHidden ? 0 : 25),
        font: previewLabel.font!, lineHeight: 20.16)
    }
    let matchHeight =
      searchMatch.isHidden
      ? 0
      : HistoryVisual.textHeight(
        searchMatch.stringValue, width: contentWidth - 38, font: searchMatch.font!,
        lineHeight: 19.02) + 21
    let margin: CGFloat = previewLabel.isHidden && !showsStatus ? 0 : 4
    return 26 + metaHeight + 6 + contentHeight + margin + matchHeight + 15.232
  }
  override func layout() {
    super.layout()
    let left: CGFloat = 14
    let width = max(1, bounds.width - 28 - 98 - 12)
    var x = left
    var y: CGFloat = 13
    for badge in badges {
      if x - left + badge.desiredWidth > width && x > left {
        x = left
        y += 22.408
      }
      badge.frame = NSRect(x: x, y: y, width: badge.desiredWidth, height: 17.408)
      x += badge.desiredWidth + 5
    }
    y += 23.408
    if expanded, previewLabel.isHidden, !showsStatus, let preview {
      let h = preview.desiredHeight(width: width)
      preview.frame = NSRect(x: left, y: y, width: width, height: h)
      preview.layoutSubtreeIfNeeded()
      y += h
    } else if showsStatus {
      status.frame = NSRect(x: left, y: y + 2, width: width - 85, height: 24)
      retryButton.frame = NSRect(x: left + width - 75, y: y, width: 75, height: 30)
      y += showsLoading ? 20 : 32
    } else {
      let offset: CGFloat = typeIcon.isHidden ? 0 : 25
      let h = HistoryVisual.textHeight(
        previewLabel.stringValue, width: width - offset, font: previewLabel.font!, lineHeight: 20.16
      )
      typeIcon.frame = NSRect(x: left, y: y + 4, width: 18, height: 18)
      previewLabel.frame = NSRect(x: left + offset, y: y, width: width - offset, height: h)
      y += h
    }
    y += previewLabel.isHidden && !showsStatus ? 0 : 4
    if !searchMatch.isHidden {
      let h = HistoryVisual.textHeight(
        searchMatch.stringValue, width: width - 38, font: searchMatch.font!, lineHeight: 19.02)
      searchIcon.frame = NSRect(x: left + 9, y: y + 9, width: 14, height: 14)
      searchMatch.frame = NSRect(x: left + 29, y: y + 7, width: width - 38, height: h)
      y += h + 21
    }
    timestamp.frame = NSRect(x: left, y: y, width: width, height: 15.232)
    let actionY = expanded ? CGFloat(13) : (bounds.height - 30) / 2
    pinButton.frame = NSRect(x: bounds.width - 14 - 98, y: actionY, width: 30, height: 30)
    restoreButton.frame = NSRect(x: bounds.width - 14 - 64, y: actionY, width: 30, height: 30)
    deleteButton.frame = NSRect(x: bounds.width - 14 - 30, y: actionY, width: 30, height: 30)
  }
  override func draw(_ rect: NSRect) {
    if item.isPinned {
      HistoryVisual.accent(self).setFill()
      NSBezierPath(
        roundedRect: NSRect(x: 0, y: 0, width: 3, height: bounds.height), xRadius: 1.5, yRadius: 1.5
      ).fill()
    }
    if !searchMatch.isHidden {
      let frame = NSRect(
        x: 14, y: searchMatch.frame.minY - 7, width: bounds.width - 28 - 98 - 12,
        height: searchMatch.frame.height + 14)
      HistoryVisual.accentFill(self).setFill()
      NSBezierPath(roundedRect: frame, xRadius: 7, yRadius: 7).fill()
      HistoryVisual.accent(self).setFill()
      NSRect(x: frame.minX, y: frame.minY, width: 3, height: frame.height).fill()
    }
    if window?.firstResponder === self && keyboardFocusVisible {
      NSColor.keyboardFocusIndicatorColor.setStroke()
      let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 9, yRadius: 9)
      path.lineWidth = 2
      path.stroke()
    }
  }
  override func mouseDown(with event: NSEvent) {
    keyboardFocusVisible = false
    focusFromMouse = true
    window?.makeFirstResponder(self)
    focusFromMouse = false
    onToggle?()
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    addTrackingArea(
      NSTrackingArea(
        rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
        owner: self))
  }
  override func mouseEntered(with event: NSEvent) {
    hovered = true
    refresh()
  }
  override func mouseExited(with event: NSEvent) {
    hovered = false
    refresh()
  }
  override func keyDown(with event: NSEvent) {
    keyboardFocusVisible = true
    needsDisplay = true
    if [36, 49, 76].contains(event.keyCode) { onToggle?() } else { super.keyDown(with: event) }
  }
  override func accessibilityPerformPress() -> Bool {
    onToggle?()
    return true
  }
  override func becomeFirstResponder() -> Bool {
    keyboardFocusVisible = !focusFromMouse
    needsDisplay = true
    return true
  }
  override func resignFirstResponder() -> Bool {
    keyboardFocusVisible = false
    needsDisplay = true
    return true
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refresh()
  }
}
