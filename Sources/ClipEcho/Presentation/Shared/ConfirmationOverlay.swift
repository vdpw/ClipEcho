import AppKit

/// Matches the existing in-window confirmation: dimmed background, centered
/// glass card, cancel-first keyboard focus, and a trapped modal interaction.
@MainActor
final class ConfirmationOverlay: NSPanel {
  private var accepted = false
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  static func run(
    in parent: NSWindow, title: String, message: String, warningText: String? = nil,
    cancelLabel: String, confirmLabel: String, destructive: Bool
  ) -> Bool {
    let previousResponder = parent.firstResponder
    let overlay = ConfirmationOverlay(
      contentRect: parent.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    overlay.title = title
    overlay.isOpaque = false
    overlay.backgroundColor = .clear
    overlay.hasShadow = false
    overlay.isReleasedWhenClosed = false
    overlay.level = parent.level
    // Dim the parent through a transparent panel instead of covering it with
    // a full-window material, whose tint hides the underlying settings.
    let root = NSView()
    root.wantsLayer = true
    root.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.24).cgColor
    overlay.contentView = root

    let card = NSVisualEffectView()
    card.material = .popover
    card.blendingMode = .withinWindow
    card.state = .active
    card.wantsLayer = true
    card.layer?.cornerRadius = 22
    card.layer?.masksToBounds = true
    card.layer?.borderWidth = 1
    card.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
    card.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(card)
    let titleLabel = NSTextField(wrappingLabelWithString: title)
    titleLabel.font = .systemFont(ofSize: 16.8, weight: .bold)
    let warning = NSImageView(image: OriginalIcons.image("exclamationmark.triangle") ?? NSImage())
    warning.contentTintColor = .systemOrange
    warning.widthAnchor.constraint(equalToConstant: 24).isActive = true
    warning.heightAnchor.constraint(equalToConstant: 24).isActive = true
    let heading = NSStackView(views: [warning, titleLabel])
    heading.orientation = .horizontal
    heading.alignment = .centerY
    heading.spacing = 12
    let body = NSTextField(wrappingLabelWithString: message)
    body.font = .systemFont(ofSize: 13)
    body.textColor = .secondaryLabelColor
    if let warningText {
      let copy = NSMutableAttributedString(
        string: message,
        attributes: [
          .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor,
        ])
      let range = (message as NSString).range(of: warningText, options: .backwards)
      if range.location != NSNotFound {
        copy.addAttribute(.foregroundColor, value: NSColor.systemRed, range: range)
      }
      body.attributedStringValue = copy
    }
    body.setContentCompressionResistancePriority(.required, for: .vertical)
    let cancel = ModalButton(title: cancelLabel, destructive: false)
    cancel.target = overlay
    cancel.action = #selector(cancelAction)
    cancel.keyEquivalent = "\u{1b}"
    let confirm = ModalButton(title: confirmLabel, destructive: destructive)
    confirm.target = overlay
    confirm.action = #selector(confirmAction)
    let actions = NSStackView(views: [NSView(), cancel, confirm])
    actions.orientation = .horizontal
    actions.alignment = .centerY
    actions.spacing = 10
    let stack = FlippedStackView(views: [heading, body, actions])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 20
    stack.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(stack)
    NSLayoutConstraint.activate([
      card.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      card.centerYAnchor.constraint(equalTo: root.centerYAnchor),
      card.widthAnchor.constraint(equalToConstant: 420),
      stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
      stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
      heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
      body.widthAnchor.constraint(equalTo: stack.widthAnchor),
      actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
      cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 86),
      confirm.widthAnchor.constraint(greaterThanOrEqualToConstant: 86),
      cancel.heightAnchor.constraint(equalToConstant: 32),
      confirm.heightAnchor.constraint(equalToConstant: 32),
    ])
    cancel.nextKeyView = confirm
    confirm.nextKeyView = cancel
    cancel.tabPartner = confirm
    confirm.tabPartner = cancel
    parent.addChildWindow(overlay, ordered: .above)
    overlay.makeKeyAndOrderFront(nil)
    overlay.makeFirstResponder(cancel)
    NSApp.runModal(for: overlay)
    parent.removeChildWindow(overlay)
    overlay.orderOut(nil)
    parent.makeKey()
    if let previousResponder { parent.makeFirstResponder(previousResponder) }
    return overlay.accepted
  }

  @objc private func cancelAction() { NSApp.stopModal() }
  @objc private func confirmAction() {
    accepted = true
    NSApp.stopModal()
  }
  override func cancelOperation(_ sender: Any?) { cancelAction() }
}

@MainActor
private final class ModalButton: NSButton {
  private let destructive: Bool
  weak var tabPartner: ModalButton?
  override var acceptsFirstResponder: Bool { true }
  override var canBecomeKeyView: Bool { true }
  init(title: String, destructive: Bool) {
    self.destructive = destructive
    super.init(frame: .zero)
    self.title = title
    isBordered = false
    font = .systemFont(ofSize: 12.2, weight: .medium)
    focusRingType = .exterior
    setAccessibilityLabel(title)
  }
  required init?(coder: NSCoder) { nil }
  private var buttonShape: NSBezierPath {
    NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
  }
  // The native button cell's mask describes its text bezel, not our custom
  // rounded background. Keep the system keyboard indicator on the same shape.
  override var focusRingMaskBounds: NSRect { bounds }
  override func drawFocusRingMask() { buttonShape.fill() }
  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 48:
      // The two-button modal keeps its focus loop even when macOS keyboard
      // navigation excludes buttons. Both Tab directions reach the other one.
      if let tabPartner { window?.makeFirstResponder(tabPartner) }
    case 36, 76, 49:
      performClick(nil)
    default:
      super.keyDown(with: event)
    }
  }
  override func draw(_ dirtyRect: NSRect) {
    let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    let color =
      destructive
      ? (dark
        ? NSColor(red: 1, green: 0.51, blue: 0.48, alpha: 1)
        : NSColor(red: 0.76, green: 0.15, blue: 0.15, alpha: 1)) : .labelColor
    let fill =
      destructive
      ? color.withAlphaComponent(isHighlighted ? 0.18 : 0.08)
      : NSColor.quaternaryLabelColor.withAlphaComponent(isHighlighted ? 0.25 : 0.14)
    let path = buttonShape
    fill.setFill()
    path.fill()
    color.withAlphaComponent(destructive ? 0.28 : 0.12).setStroke()
    path.lineWidth = 1
    path.stroke()
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font ?? NSFont.systemFont(ofSize: 12), .foregroundColor: color,
    ]
    let size = title.size(withAttributes: attributes)
    title.draw(
      at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
      withAttributes: attributes)
  }
}
