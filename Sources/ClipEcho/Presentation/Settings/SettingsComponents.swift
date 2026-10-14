import AppKit

/// The settings screen has its own semantic palette in the original app.
@MainActor
enum SettingsPalette {
  static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
      srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
      blue: CGFloat(value & 255) / 255, alpha: alpha)
  }
  static func adaptive(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(name: nil) { appearance in
      let darkMode = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      return hex(darkMode ? dark : light, alpha: alpha)
    }
  }
  static func adaptive(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat, darkAlpha: CGFloat)
    -> NSColor
  {
    NSColor(name: nil) { appearance in
      let darkMode = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      return hex(darkMode ? dark : light, alpha: darkMode ? darkAlpha : lightAlpha)
    }
  }
  static let canvas = adaptive(0xffffff, 0x292726)
  static let surface = adaptive(0xf6f6f6, 0x32302f)
  static let primary = adaptive(0x292827, 0xf0efee)
  static var secondary: NSColor {
    NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
      ? primary : adaptive(0x6e6c69, 0xaaa7a5)
  }
  static var tertiary: NSColor {
    NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
      ? primary : adaptive(0x6b6967, 0xa29f9d)
  }
  static let sidebar = adaptive(0xecebea, 0x2b2928)
  static let controlSurface = adaptive(0xffffff, 0x403d3b)
  static var border: NSColor {
    NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
      ? primary : adaptive(0x3c3a37, 0xfffaf5, lightAlpha: 0.19, darkAlpha: 0.16)
  }
  static var inputBorder: NSColor {
    NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
      ? primary : adaptive(0x3c3a37, 0xfffaf5, lightAlpha: 0.12, darkAlpha: 0.10)
  }
  static var separator: NSColor {
    NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
      ? primary : adaptive(0x3c3a37, 0xfffaf5, lightAlpha: 0.08, darkAlpha: 0.06)
  }
  static var groupBorder: NSColor {
    NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
      ? primary : adaptive(0x3c3a37, 0xfffaf5, alpha: 0.015)
  }
  static let fill = adaptive(0x3c3a37, 0xfffaf5, lightAlpha: 0.075, darkAlpha: 0.08)
  static let accent = adaptive(0x0068df, 0x1870d8)
  static let accentFill = adaptive(0x0068df, 0x4696ff, lightAlpha: 0.09, darkAlpha: 0.16)
  static let selected = hex(0x076cf0)
  static let inactiveSelected = adaptive(0xd8d6d4, 0x4b4846)
  static let danger = adaptive(0xc32627, 0xff827a)
  static let dangerFill = adaptive(0xc32627, 0xff6464, lightAlpha: 0.08, darkAlpha: 0.10)
}

@MainActor
class SettingsSurface: NSView {
  var color: NSColor = SettingsPalette.canvas
  var stroke: NSColor?
  var radius: CGFloat = 0
  override var isFlipped: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(
      roundedRect: bounds.insetBy(dx: stroke == nil ? 0 : 0.5, dy: stroke == nil ? 0 : 0.5),
      xRadius: radius, yRadius: radius)
    color.setFill()
    path.fill()
    if let stroke {
      stroke.setStroke()
      path.lineWidth = 1
      path.stroke()
    }
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}

@MainActor
final class SettingsHeaderDragSurface: SettingsSurface {
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit is NSTextField ? self : hit
  }
  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
  }
}

@MainActor
final class SettingsDragRegion: NSView {
  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
  }
}

@MainActor
final class SettingsDivider: NSView {
  override func draw(_ dirtyRect: NSRect) {
    SettingsPalette.separator.setFill()
    bounds.fill()
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}

@MainActor
final class SettingsButton: NSButton {
  enum Style { case primary, secondary, danger, back, help, dismiss }
  let style: Style
  var handler: (@MainActor () -> Void)?
  var symbol: String?
  var expanded = false { didSet { needsDisplay = true } }
  init(
    _ title: String, style: Style = .secondary, symbol: String? = nil,
    handler: @escaping @MainActor () -> Void
  ) {
    self.style = style
    self.symbol = symbol
    self.handler = handler
    super.init(frame: .zero)
    self.title = title
    self.font = .systemFont(ofSize: 13)
    isBordered = false
    focusRingType = .none
    target = self
    action = #selector(activate)
    setAccessibilityLabel(title)
    setContentHuggingPriority(.required, for: .horizontal)
    setContentCompressionResistancePriority(.required, for: .horizontal)
  }
  required init?(coder: NSCoder) { nil }
  override var isFlipped: Bool { true }
  override var intrinsicContentSize: NSSize {
    if style == .help || style == .dismiss { return NSSize(width: 22, height: 22) }
    let width = (title as NSString).size(withAttributes: [
      .font: font ?? NSFont.systemFont(ofSize: 13)
    ]).width
    return NSSize(
      width: ceil(width) + (style == .back ? 21 : 20)
        + (symbol == nil ? 0 : (style == .back ? 25 : 21)), height: style == .back ? 32 : 26)
  }
  @objc private func activate() { handler?() }
  override func draw(_ dirtyRect: NSRect) {
    let enabled = isEnabled
    let textColor: NSColor =
      !enabled
      ? SettingsPalette.tertiary
      : style == .primary
        ? .white : style == .danger ? SettingsPalette.danger : SettingsPalette.primary
    if style == .help, expanded || isHighlighted {
      SettingsPalette.accentFill.setFill()
      NSBezierPath(ovalIn: bounds).fill()
    }
    if style != .help && style != .dismiss {
      let fill: NSColor =
        !enabled
        ? SettingsPalette.fill
        : style == .primary
          ? SettingsPalette.accent
          : style == .danger
            ? SettingsPalette.dangerFill
            : style == .back ? SettingsPalette.controlSurface : SettingsPalette.fill
      fill.setFill()
      let path = NSBezierPath(
        roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: style == .back ? 18 : 6,
        yRadius: style == .back ? 18 : 6)
      path.fill()
      if style == .back {
        SettingsPalette.border.setStroke()
        path.lineWidth = 1
        path.stroke()
      }
      if isHighlighted {
        NSColor.black.withAlphaComponent(0.07).setFill()
        path.fill()
      }
    }
    var x: CGFloat = style == .back ? 9 : 10
    if let symbol, let image = OriginalIcons.image(symbol) {
      let size: CGFloat = style == .back ? 17 : style == .help ? 14 : 13
      let iconRect = NSRect(
        x: style == .help || style == .dismiss ? (bounds.width - size) / 2 : x,
        y: (bounds.height - size) / 2, width: size, height: size)
      image.settingsDraw(
        in: iconRect,
        color: style == .help
          ? (expanded || isHighlighted ? SettingsPalette.accent : SettingsPalette.secondary)
          : textColor)
      x += size + (style == .back ? 8 : 6)
    }
    if !title.isEmpty {
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineBreakMode = .byTruncatingTail
      let attributes: [NSAttributedString.Key: Any] = [
        .font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: textColor,
        .paragraphStyle: paragraph,
      ]
      let h = (title as NSString).size(withAttributes: attributes).height
      (title as NSString).draw(
        in: NSRect(
          x: x, y: (bounds.height - h) / 2, width: max(0, bounds.width - x - 7), height: h),
        withAttributes: attributes)
    }
    if window?.firstResponder === self {
      SettingsPalette.selected.setStroke()
      let focus = NSBezierPath(
        roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: style == .back ? 16 : 5,
        yRadius: style == .back ? 16 : 5)
      focus.lineWidth = 2
      focus.stroke()
    }
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}

@MainActor
extension NSImage {
  fileprivate func settingsDraw(in rect: NSRect, color: NSColor) {
    let tinted = NSImage(size: size, flipped: false) { area in
      self.draw(in: area)
      color.setFill()
      area.fill(using: .sourceIn)
      return true
    }
    tinted.draw(
      in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
  }
}

@MainActor
final class SettingsCategoryButton: NSButton {
  var selected = false {
    didSet {
      needsDisplay = true
      setAccessibilityValue(selected ? 1 : 0)
    }
  }
  let index: Int
  var handler: (@MainActor () -> Void)?
  init(index: Int, title: String, handler: @escaping @MainActor () -> Void) {
    self.index = index
    self.handler = handler
    super.init(frame: .zero)
    self.title = title
    isBordered = false
    focusRingType = .none
    target = self
    action = #selector(activate)
    setAccessibilityLabel(title)
  }
  required init?(coder: NSCoder) { nil }
  override var isFlipped: Bool { true }
  override var intrinsicContentSize: NSSize { NSSize(width: 160, height: 32) }
  @objc private func activate() { handler?() }
  override func draw(_ dirtyRect: NSRect) {
    if selected {
      (window?.isKeyWindow == false ? SettingsPalette.inactiveSelected : SettingsPalette.selected)
        .setFill()
      NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    } else if isHighlighted {
      SettingsPalette.fill.setFill()
      NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
    let icon = NSRect(x: 8, y: (bounds.height - 20) / 2, width: 20, height: 20)
    let pairs: [(UInt32, UInt32)] = [
      (0xaaa9ae, 0x89898e), (0x292929, 0x101010), (0x079aff, 0x007df2), (0xaaa9ae, 0x89898e),
    ]
    NSGradient(
      starting: SettingsPalette.hex(pairs[index].0), ending: SettingsPalette.hex(pairs[index].1))?
      .draw(in: NSBezierPath(roundedRect: icon, xRadius: 5, yRadius: 5), angle: 90)
    let symbol = ["gearshape", "circle.lefthalf.filled", "doc.on.clipboard", "menubar.rectangle"][
      index]
    OriginalIcons.image(symbol)?.settingsDraw(in: icon.insetBy(dx: 2.5, dy: 2.5), color: .white)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 13.5, weight: selected ? .semibold : .regular),
      .foregroundColor: selected && window?.isKeyWindow != false
        ? NSColor.white : SettingsPalette.primary,
    ]
    let h = (title as NSString).size(withAttributes: attributes).height
    (title as NSString).draw(
      in: NSRect(x: 36, y: (bounds.height - h) / 2, width: bounds.width - 44, height: h),
      withAttributes: attributes)
    if window?.firstResponder === self {
      SettingsPalette.primary.setStroke()
      let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
      p.lineWidth = 2
      p.stroke()
    }
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}

@MainActor
final class SettingsSwitch: NSButton {
  var handler: (@MainActor (Bool) -> Void)?
  init(value: Bool, label: String, handler: @escaping @MainActor (Bool) -> Void) {
    self.handler = handler
    super.init(frame: .zero)
    setButtonType(.toggle)
    isBordered = false
    focusRingType = .none
    state = value ? .on : .off
    target = self
    action = #selector(activate)
    setAccessibilityLabel(label)
    setAccessibilityRole(.checkBox)
    widthAnchor.constraint(equalToConstant: 36).isActive = true
    heightAnchor.constraint(equalToConstant: 18).isActive = true
  }
  required init?(coder: NSCoder) { nil }
  override var isFlipped: Bool { true }
  override var intrinsicContentSize: NSSize { NSSize(width: 36, height: 18) }
  @objc private func activate() {
    setAccessibilityValue(state == .on ? 1 : 0)
    handler?(state == .on)
    needsDisplay = true
  }
  override func draw(_ dirtyRect: NSRect) {
    let on = state == .on
    (on ? SettingsPalette.accent : SettingsPalette.fill).setFill()
    let track = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
    track.fill()
    if !on {
      SettingsPalette.border.setStroke()
      track.lineWidth = 1
      track.stroke()
    }
    NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.7).setFill()
    let thumb = NSBezierPath(
      roundedRect: NSRect(x: on ? 14 : 2, y: 2, width: 20, height: 14), xRadius: 8, yRadius: 8)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
    shadow.shadowBlurRadius = 2
    shadow.shadowOffset = NSSize(width: 0, height: 1)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    thumb.fill()
    NSGraphicsContext.restoreGraphicsState()
    if !isEnabled {
      SettingsPalette.canvas.withAlphaComponent(0.25).setFill()
      track.fill()
    }
    if window?.firstResponder === self {
      SettingsPalette.selected.setStroke()
      track.lineWidth = 2
      track.stroke()
    }
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}

@MainActor
final class SettingsPopup: NSPopUpButton {
  var handler: (@MainActor (SettingsPopup) -> Void)?
  init(handler: @escaping @MainActor (SettingsPopup) -> Void) {
    self.handler = handler
    super.init(frame: .zero, pullsDown: false)
    isBordered = false
    focusRingType = .none
    font = .systemFont(ofSize: 13)
    target = self
    action = #selector(activate)
    widthAnchor.constraint(equalToConstant: 124).isActive = true
    heightAnchor.constraint(equalToConstant: 26).isActive = true
  }
  required init?(coder: NSCoder) { nil }
  @objc private func activate() {
    handler?(self)
    needsDisplay = true
  }
  override var isFlipped: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    SettingsPalette.controlSurface.setFill()
    let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
    p.fill()
    SettingsPalette.inputBorder.setStroke()
    p.lineWidth = 1
    p.stroke()
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 13),
      .foregroundColor: isEnabled ? SettingsPalette.primary : SettingsPalette.tertiary,
    ]
    let h = ((titleOfSelectedItem ?? "") as NSString).size(withAttributes: attrs).height
    ((titleOfSelectedItem ?? "") as NSString).draw(
      in: NSRect(x: 7, y: (bounds.height - h) / 2, width: bounds.width - 24, height: h),
      withAttributes: attrs)
    NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 9, weight: .medium))?.settingsDraw(
        in: NSRect(x: bounds.width - 16, y: 9, width: 9, height: 8),
        color: SettingsPalette.secondary)
    if window?.firstResponder === self {
      SettingsPalette.selected.setStroke()
      p.lineWidth = 2
      p.stroke()
    }
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}

@MainActor
final class SettingsNumberField: NSTextField {
  var step: (@MainActor (Int) -> Void)?
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 126 {
      step?(1)
    } else if event.keyCode == 125 {
      step?(-1)
    } else {
      super.keyDown(with: event)
    }
  }
}

@MainActor
final class SettingsNumberInput: NSView {
  let field = SettingsNumberField(string: "")
  let stepper = NSStepper()
  override var isFlipped: Bool { true }
  init(value: String, width: CGFloat, label: String) {
    super.init(frame: .zero)
    field.stringValue = value
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    field.textColor = SettingsPalette.primary
    field.alignment = .left
    field.setAccessibilityLabel(label)
    field.translatesAutoresizingMaskIntoConstraints = false
    addSubview(field)
    stepper.controlSize = .mini
    stepper.minValue = -1
    stepper.maxValue = 1
    stepper.increment = 1
    stepper.autorepeat = true
    stepper.target = self
    stepper.action = #selector(stepNumber)
    stepper.translatesAutoresizingMaskIntoConstraints = false
    stepper.setAccessibilityLabel(label)
    addSubview(stepper)
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: width), heightAnchor.constraint(equalToConstant: 26),
      field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
      field.trailingAnchor.constraint(equalTo: stepper.leadingAnchor, constant: -3),
      field.centerYAnchor.constraint(equalTo: centerYAnchor),
      stepper.widthAnchor.constraint(equalToConstant: 12),
      stepper.heightAnchor.constraint(equalToConstant: 20),
      stepper.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
      stepper.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }
  required init?(coder: NSCoder) { nil }
  @objc private func stepNumber() {
    let direction = stepper.integerValue
    stepper.integerValue = 0
    field.step?(direction)
  }
  override func draw(_ dirtyRect: NSRect) {
    SettingsPalette.controlSurface.setFill()
    let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
    p.fill()
    SettingsPalette.inputBorder.setStroke()
    p.lineWidth = 1
    p.stroke()
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}

@MainActor
final class SettingsThemeButton: NSButton {
  let theme: String
  var chosen: Bool = false {
    didSet {
      state = chosen ? .on : .off
      needsDisplay = true
      setAccessibilityValue(chosen ? 1 : 0)
    }
  }
  var handler: (@MainActor () -> Void)?
  init(theme: String, title: String, chosen: Bool, handler: @escaping @MainActor () -> Void) {
    self.theme = theme
    self.chosen = chosen
    self.handler = handler
    super.init(frame: .zero)
    self.title = title
    setButtonType(.radio)
    state = chosen ? .on : .off
    isBordered = false
    focusRingType = .none
    target = self
    action = #selector(activate)
    setAccessibilityLabel(title)
    setAccessibilityRole(.radioButton)
    setAccessibilityValue(chosen ? 1 : 0)
    widthAnchor.constraint(equalToConstant: 68).isActive = true
    heightAnchor.constraint(equalToConstant: 65.3).isActive = true
  }
  required init?(coder: NSCoder) { nil }
  override var isFlipped: Bool { true }
  override var wantsDefaultClipping: Bool { false }
  @objc private func activate() {
    if isEnabled && !chosen { handler?() }
  }
  override func mouseDown(with event: NSEvent) {
    guard isEnabled else { return }
    window?.makeFirstResponder(self)
    // The full custom-drawn card is the hit target. NSButtonCell's radio
    // indicator/title hit region does not match this thumbnail and label.
    activate()
  }
  override func accessibilityPerformPress() -> Bool {
    guard isEnabled else { return false }
    activate()
    return true
  }
  override func keyDown(with event: NSEvent) {
    if [36, 49, 76].contains(event.keyCode) {
      activate()
      return
    }
    guard [123, 124, 125, 126].contains(event.keyCode) else {
      super.keyDown(with: event)
      return
    }
    let choices = superview?.subviews.compactMap { $0 as? SettingsThemeButton } ?? []
    guard let index = choices.firstIndex(where: { $0 === self }), !choices.isEmpty else { return }
    let increment = event.keyCode == 124 || event.keyCode == 125 ? 1 : -1
    let next = choices[(index + increment + choices.count) % choices.count]
    if next.isEnabled {
      window?.makeFirstResponder(next)
      next.activate()
    }
  }
  override func draw(_ dirtyRect: NSRect) {
    let preview = NSRect(x: 0, y: 0, width: 68, height: 46)
    let clip = NSBezierPath(roundedRect: preview, xRadius: 5, yRadius: 5)
    NSGraphicsContext.saveGraphicsState()
    clip.addClip()
    if theme == "system" {
      NSGraphicsContext.saveGraphicsState()
      NSBezierPath(rect: NSRect(x: 0, y: 0, width: 34, height: 46)).addClip()
      drawScene(dark: false)
      NSGraphicsContext.restoreGraphicsState()
      NSGraphicsContext.saveGraphicsState()
      NSBezierPath(rect: NSRect(x: 34, y: 0, width: 34, height: 46)).addClip()
      drawScene(dark: true)
      NSGraphicsContext.restoreGraphicsState()
    } else {
      drawScene(dark: theme == "dark")
    }
    NSGraphicsContext.restoreGraphicsState()
    NSColor.black.withAlphaComponent(0.2).setStroke()
    clip.lineWidth = 0.5
    clip.stroke()
    if chosen {
      SettingsPalette.selected.setStroke()
      let ring = NSBezierPath(
        roundedRect: preview.insetBy(dx: -3.25, dy: -3.25), xRadius: 7, yRadius: 7)
      ring.lineWidth = 2.5
      ring.stroke()
    }
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11),
      .foregroundColor: chosen ? SettingsPalette.primary : SettingsPalette.secondary,
      .paragraphStyle: paragraph,
    ]
    (title as NSString).draw(in: NSRect(x: -5, y: 51, width: 78, height: 16), withAttributes: attrs)
    if window?.firstResponder === self {
      SettingsPalette.selected.withAlphaComponent(0.3).setStroke()
      let focus = NSBezierPath(
        roundedRect: preview.insetBy(dx: -6, dy: -6), xRadius: 10, yRadius: 10)
      focus.lineWidth = 3
      focus.stroke()
    }
  }
  private func drawScene(dark: Bool) {
    let desktop = NSRect(x: 0, y: 0, width: 68, height: 46)
    let colors: [NSColor] =
      dark
      ? [
        SettingsPalette.hex(0x124777), SettingsPalette.hex(0x001d46), SettingsPalette.hex(0x03345f),
        SettingsPalette.hex(0x056496),
      ]
      : [
        SettingsPalette.hex(0x83d8f5), SettingsPalette.hex(0x0777df), SettingsPalette.hex(0x078be9),
        SettingsPalette.hex(0x46d4ee),
      ]
    NSGradient(colors: colors)?.draw(in: desktop, angle: 55)
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: 30, yBy: 2.5)
    transform.rotate(byDegrees: -29)
    transform.concat()
    NSGradient(
      starting: SettingsPalette.hex(dark ? 0x1064a8 : 0xa7e8f9),
      ending: SettingsPalette.hex(dark ? 0x054681 : 0x2fb8f1))?.draw(
        in: NSBezierPath(ovalIn: NSRect(x: -47, y: -18.5, width: 94, height: 37)), angle: 0)
    NSGraphicsContext.restoreGraphicsState()
    drawWindow(NSRect(x: 5, y: 6, width: 40, height: 23), dark: dark, front: false)
    drawWindow(NSRect(x: 16, y: 24, width: 52, height: 27), dark: dark, front: true)
  }
  private func drawWindow(_ rect: NSRect, dark: Bool, front: Bool) {
    let p = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.2)
    shadow.shadowBlurRadius = 4
    shadow.shadowOffset = NSSize(width: 0, height: 2)
    shadow.set()
    SettingsPalette.hex(dark ? 0x32343a : 0xfafbfc).setFill()
    p.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    p.addClip()
    SettingsPalette.hex(dark ? 0x1d2026 : 0xe9ecf0).setFill()
    NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: front ? 8 : 5).fill()
    if front {
      for (i, color) in [UInt32(0xff6058), 0xfebc2e, 0x28c840].enumerated() {
        SettingsPalette.hex(color).setFill()
        NSBezierPath(
          ovalIn: NSRect(x: rect.minX + 8 + CGFloat(i) * 10, y: rect.minY + 10, width: 6, height: 6)
        ).fill()
      }
    } else {
      SettingsPalette.hex(0x228bea).setFill()
      NSBezierPath(
        roundedRect: NSRect(x: rect.minX + 3, y: rect.minY + 8, width: 34, height: 3), xRadius: 1,
        yRadius: 1
      ).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    SettingsPalette.hex(dark ? 0x000000 : 0x1f314b, alpha: dark ? 0.65 : 0.3).setStroke()
    p.lineWidth = 0.5
    p.stroke()
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}

@MainActor
final class SettingsHelpBubble: SettingsSurface {
  let requiredHeight: CGFloat
  init(message: String, width: CGFloat) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = 19.5
    paragraph.maximumLineHeight = 19.5
    let copy = NSAttributedString(
      string: message,
      attributes: [
        .font: NSFont.systemFont(ofSize: 13), .foregroundColor: SettingsPalette.primary,
        .paragraphStyle: paragraph,
      ])
    let measured = copy.boundingRect(
      with: NSSize(width: width - 26, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading])
    requiredHeight = max(45, ceil(measured.height) + 22)
    super.init(frame: NSRect(x: 0, y: 0, width: width, height: requiredHeight))
    color = SettingsPalette.controlSurface
    stroke = SettingsPalette.border
    radius = 10
    wantsLayer = true
    layer?.shadowColor = NSColor.black.withAlphaComponent(0.18).cgColor
    layer?.shadowOpacity = 1
    layer?.shadowRadius = 11
    layer?.shadowOffset = CGSize(width: 0, height: -6)
    setAccessibilityRole(.group)
    setAccessibilityLabel(message)
    let text = NSTextField(wrappingLabelWithString: message)
    text.attributedStringValue = copy
    text.translatesAutoresizingMaskIntoConstraints = false
    addSubview(text)
    NSLayoutConstraint.activate([
      text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
      text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
      text.topAnchor.constraint(equalTo: topAnchor, constant: 11),
      text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
    ])
  }
  required init?(coder: NSCoder) { nil }
}
