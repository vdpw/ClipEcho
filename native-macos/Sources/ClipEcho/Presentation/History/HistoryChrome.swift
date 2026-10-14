import AppKit

@MainActor
final class HistoryRootView: NSView {
  var onLayout: (() -> Void)?
  override var isFlipped: Bool { true }
  override func layout() {
    super.layout()
    onLayout?()
  }
  override func draw(_ rect: NSRect) {
    HistoryVisual.canvas(self).setFill()
    bounds.fill()
  }
}
@MainActor
final class HistoryDocumentView: NSView {
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override func draw(_ rect: NSRect) {
    HistoryVisual.canvas(self).setFill()
    bounds.fill()
  }
}
@MainActor
final class HistoryDragStrip: NSVisualEffectView {
  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
  }
}
@MainActor
final class HistoryCountView: NSView {
  var value = "0" { didSet { needsDisplay = true } }
  var desiredWidth: CGFloat {
    max(
      25,
      ceil(
        (value as NSString).size(withAttributes: [
          .font: NSFont.systemFont(ofSize: 11.52, weight: .semibold)
        ]).width) + 14)
  }
  override func draw(_ rect: NSRect) {
    HistoryVisual.controlFill(self).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11.52, weight: .semibold),
      .foregroundColor: HistoryVisual.secondary(self),
    ]
    let size = (value as NSString).size(withAttributes: attributes)
    (value as NSString).draw(
      at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
      withAttributes: attributes)
  }
}
@MainActor
final class HistorySearchView: NSVisualEffectView {
  let input = NSTextField()
  let clearButton = HistoryActionButton(symbol: "xmark", label: "")
  var onClear: (() -> Void)?
  var focused = false {
    didSet {
      needsDisplay = true
      paint.needsDisplay = true
      needsLayout = true
    }
  }
  private let icon = NSImageView(
    image: OriginalIcons.image("magnifyingglass") ?? NSImage())
  private let shortcut = HistoryLabel(
    "⌘F", size: 10.56, weight: .medium, lineHeight: 13, singleLine: true)
  private let paint = HistorySearchPaintView()
  override var isFlipped: Bool { true }
  override init(frame: NSRect) {
    super.init(frame: frame)
    material = .popover
    blendingMode = .withinWindow
    state = .active
    paint.owner = self
    addSubview(paint)
    wantsLayer = true
    layer?.cornerRadius = 15
    layer?.shadowOpacity = 0.06
    layer?.shadowRadius = 8
    layer?.shadowOffset = NSSize(width: 0, height: -4)
    input.isBordered = false
    input.isBezeled = false
    input.drawsBackground = false
    input.font = .systemFont(ofSize: 13.44)
    input.focusRingType = .none
    input.lineBreakMode = .byClipping
    for child in [icon, input, clearButton, shortcut] { addSubview(child) }
    clearButton.onClick = { [weak self] in self?.onClear?() }
  }
  required init?(coder: NSCoder) { nil }
  override func layout() {
    super.layout()
    paint.frame = bounds
    paint.needsDisplay = true
    let clear = !input.stringValue.isEmpty
    clearButton.isHidden = !clear
    icon.frame = NSRect(x: 12, y: 12, width: 18, height: 18)
    let shortcutWidth = shortcut.textWidth
    let shortcutEnd = bounds.width - 18
    shortcut.frame = NSRect(
      x: shortcutEnd - shortcutWidth, y: 14.5, width: shortcutWidth, height: 13)
    clearButton.frame = NSRect(x: shortcut.frame.minX - 6 - 9 - 28, y: 7, width: 28, height: 28)
    let inputEnd = clear ? clearButton.frame.minX - 9 : shortcut.frame.minX - 6 - 9
    input.frame = NSRect(
      x: 39, y: 11, width: max(1, inputEnd - 39), height: 22)
    input.textColor = HistoryVisual.text(self)
    shortcut.textColor = HistoryVisual.tertiary(self)
    icon.contentTintColor = focused ? HistoryVisual.accent(self) : HistoryVisual.secondary(self)
  }
  fileprivate func drawChrome(_ rect: NSRect) {
    HistoryVisual.color(0xfafafc, 0x2f2f34, in: self).withAlphaComponent(
      HistoryVisual.isDark(self) ? 0.85 : 0.82
    ).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 15, yRadius: 15).fill()
    (focused
      ? HistoryVisual.color(0x0068df, 0x50a0ff, in: self).withAlphaComponent(
        HistoryVisual.isDark(self) ? 0.4 : 0.28)
      : NSColor.white.withAlphaComponent(HistoryVisual.isDark(self) ? 0.09 : 0.9))
      .setStroke()
    let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 15, yRadius: 15)
    edge.lineWidth = 1
    edge.stroke()
    HistoryVisual.separator(self).setStroke()
    let inner = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14)
    inner.lineWidth = 0.5
    inner.stroke()
    if focused {
      HistoryVisual.focusRing(self).setStroke()
      let ring = NSBezierPath(
        roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 15, yRadius: 15)
      ring.lineWidth = 3
      ring.stroke()
    }
    HistoryVisual.surface(self).setFill()
    let shortcutBox = NSBezierPath(
      roundedRect: shortcut.frame.insetBy(dx: -6, dy: -3), xRadius: 5, yRadius: 5)
    shortcutBox.fill()
    HistoryVisual.separator(self).setStroke()
    shortcutBox.lineWidth = 1
    shortcutBox.stroke()
  }
}

/// AppKit composites a visual-effect view's own drawing below its effect layer.
/// Keep the original border/fill/shortcut chrome in a nonvibrant child above it.
@MainActor
private final class HistorySearchPaintView: NSView {
  weak var owner: HistorySearchView?
  override var isFlipped: Bool { true }
  override var allowsVibrancy: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func draw(_ rect: NSRect) { owner?.drawChrome(rect) }
}
@MainActor
final class HistoryEmptyView: NSView {
  var title = ""
  var message = ""
  private let heading = HistoryLabel(size: 17.28, weight: .bold)
  private let copy = HistoryLabel(size: 13.12)
  override var isFlipped: Bool { true }
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 14
    layer?.borderWidth = 1
    heading.alignment = .center
    copy.alignment = .center
    addSubview(heading)
    addSubview(copy)
  }
  required init?(coder: NSCoder) { nil }
  override func layout() {
    super.layout()
    heading.stringValue = title
    copy.stringValue = message
    heading.textColor = HistoryVisual.text(self)
    copy.textColor = HistoryVisual.secondary(self)
    layer?.backgroundColor = HistoryVisual.surface(self).cgColor
    layer?.borderColor = HistoryVisual.separator(self).cgColor
    heading.frame = NSRect(x: 24, y: 44, width: max(1, bounds.width - 48), height: 24)
    copy.frame = NSRect(
      x: 24, y: title.isEmpty ? 20 : 76, width: max(1, bounds.width - 48), height: 52)
  }
}
@MainActor
final class HistoryNoticeView: NSView {
  var message = ""
  var language = "system"
  var canRetry = true
  var onDismiss: (() -> Void)?
  var onRetry: (() -> Void)?
  private let warning: Bool
  private let label = HistoryLabel(size: 12.8)
  private let dismiss = HistoryActionButton(symbol: "xmark", label: "")
  private let retry = HistoryActionButton(title: "", label: "", style: .secondary)
  override var isFlipped: Bool { true }
  init(warning: Bool) {
    self.warning = warning
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 12
    layer?.borderWidth = 1
    addSubview(label)
    addSubview(dismiss)
    addSubview(retry)
    dismiss.onClick = { [weak self] in self?.onDismiss?() }
    retry.onClick = { [weak self] in self?.onRetry?() }
    retry.isHidden = warning
  }
  required init?(coder: NSCoder) { nil }
  func desiredHeight(width: CGFloat) -> CGFloat {
    max(
      46,
      HistoryVisual.textHeight(message, width: width - 116, font: label.font!, lineHeight: 19.2)
        + 24)
  }
  override func layout() {
    super.layout()
    retry.isHidden = warning || !canRetry
    label.stringValue = message
    label.textColor = warning ? .systemOrange : .systemRed
    label.frame = NSRect(
      x: 12, y: 12, width: max(1, bounds.width - 116), height: bounds.height - 24)
    dismiss.frame = NSRect(x: bounds.width - 36, y: 8, width: 28, height: 28)
    retry.frame = NSRect(x: bounds.width - 106, y: 8, width: 64, height: 30)
    retry.title = L10n.string("retry", language: language)
    dismiss.setAccessibilityLabel(
      L10n.string("dismiss", language: language))
    layer?.backgroundColor =
      (warning ? NSColor.systemOrange : NSColor.systemRed).withAlphaComponent(0.08).cgColor
    layer?.borderColor = HistoryVisual.separator(self).cgColor
  }
}
