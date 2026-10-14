import AppKit

/// Settings copy keeps its full height at the width left by the adjacent control.
/// AppKit's attributed wrapping label otherwise keeps a one-line intrinsic height
/// until its preferred width is supplied, which lets a centered row clip its copy.
@MainActor
final class SettingsWrappingLabel: NSTextField {
  init(_ text: String) {
    super.init(frame: .zero)
    isEditable = false
    isSelectable = false
    isBezeled = false
    drawsBackground = false
    maximumNumberOfLines = 0
    lineBreakMode = .byWordWrapping
    cell?.wraps = true
    cell?.isScrollable = false
    stringValue = text
  }
  required init?(coder: NSCoder) { nil }

  override var intrinsicContentSize: NSSize {
    let natural = super.intrinsicContentSize
    guard bounds.width > 0, let cell else { return natural }
    let size = cell.cellSize(
      forBounds: NSRect(
        x: 0, y: 0, width: bounds.width, height: .greatestFiniteMagnitude))
    return NSSize(width: natural.width, height: ceil(size.height))
  }

  override func setFrameSize(_ newSize: NSSize) {
    let widthChanged = abs(newSize.width - frame.width) > 0.5
    super.setFrameSize(newSize)
    if widthChanged { invalidateIntrinsicContentSize() }
  }
}
