import AppKit

/// Scroll documents must use AppKit's top-left coordinate system so short
/// content stays at the top and longer content shares the same scroll origin.
@MainActor
final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}
