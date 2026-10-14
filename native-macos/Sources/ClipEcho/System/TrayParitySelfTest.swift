import AppKit
import ClipEchoCore
import CoreFoundation

/// Synthetic checks against fixed examples from Rust's tray/preview tests.
/// This performs no clipboard reads, window operations or database access.
enum TrayParitySelfTest {
  enum Failure: Error { case assertion }
  @MainActor private final class DeliveryProbe { var mode: String? }
  @MainActor static func runTrackingDelivery() throws {
    let probe = DeliveryProbe()
    let keepAlive = Timer(timeInterval: 0.05, repeats: true) { _ in }
    RunLoop.main.add(keepAlive, forMode: .eventTracking)
    defer { keepAlive.invalidate() }
    let dispatch = Task.detached {
      MenuTrackingDelivery.post {
        probe.mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain()).map { $0.rawValue as String }
      }
    }
    defer { dispatch.cancel() }
    let deadline = CFAbsoluteTimeGetCurrent() + 1
    while probe.mode == nil && CFAbsoluteTimeGetCurrent() < deadline {
      CFRunLoopRunInMode(
        CFRunLoopMode(rawValue: RunLoop.Mode.eventTracking.rawValue as CFString), 0.05, true)
    }
    guard probe.mode == RunLoop.Mode.eventTracking.rawValue else { throw Failure.assertion }
  }
  @MainActor private static func previewFitsTextView(_ layout: TrayPresentation.PreviewLayout) -> Bool {
    let view = NSTextView(frame: NSRect(origin: .zero, size: layout.size))
    view.isHorizontallyResizable = false
    view.isVerticallyResizable = false
    view.textContainerInset = TrayPresentation.previewInsets
    view.textContainer?.widthTracksTextView = true
    view.textContainer?.lineFragmentPadding = 0
    view.textStorage?.setAttributedString(
      NSAttributedString(string: layout.text, attributes: TrayPresentation.previewAttributes))
    guard let manager = view.layoutManager, let container = view.textContainer else { return false }
    manager.ensureLayout(for: container)
    let height = max(manager.usedRect(for: container).maxY, manager.extraLineFragmentRect.maxY)
    return ceil(height) + view.textContainerInset.height * 2 <= layout.size.height
  }

  @MainActor static func run() throws {
    func require(_ value: Bool) throws { if !value { throw Failure.assertion } }
    let pinned = HistoryItem(
      contentHash: String(repeating: "a", count: 64), dataType: "text",
      display: Data(String(repeating: "固定项目内容", count: 20).utf8), displayTruncated: false,
      timestamp: 0, sourceBundleID: nil, isRemoteClipboard: false, byteCount: 0, isPinned: true)
    let label = TrayPresentation.label(pinned, language: "zh-CN")
    try require(
      label.hasPrefix("📌 ") && label.hasSuffix("...") && TrayPresentation.displayWidth(label) <= 40)
    try require(TrayPresentation.string("search", language: "zh-CN") == "搜索剪贴板…")
    try require(
      !TrayPresentation.needsPreview(title: "📌 short text", text: "short text", pinned: true))
    try require(
      !TrayPresentation.needsPreview(title: "📌 📌 user text", text: "📌 user text", pinned: true))
    try require(
      TrayPresentation.needsPreview(
        title: "short...", text: "short text with more content", pinned: false))
    let small = TrayPresentation.previewLayout(
      "short preview", availableWidth: 500, availableHeight: 700)
    try require(small?.size.width == 180 && small?.size.height == 36)
    let wide = TrayPresentation.previewLayout(
      String(repeating: "x", count: 80), availableWidth: 500, availableHeight: 700)
    try require(wide?.size.width == 380)
    let long = TrayPresentation.previewLayout(
      String(repeating: "line\n", count: 100), availableWidth: 500, availableHeight: 120)
    try require(long?.text.hasSuffix("...") == true && (long?.size.height ?? 0) <= 120)
    let samples = [
      "export CLIPECHO_SYNTHETIC_SETTING=\"" + String(repeating: "abc123", count: 14)
        + "\"\nexport CLIPECHO_SYNTHETIC_SECOND=\"" + String(repeating: "xyz789", count: 14) + "\"",
      String(repeating: "word wrapped preview ", count: 20),
      "第一行中文与 emoji 👩🏽‍💻\n" + String(repeating: "混合 abc 👨‍👩‍👧‍👦\t", count: 20),
      String(repeating: "\tindented text\n", count: 80),
    ]
    for (index, sample) in samples.enumerated() {
      guard let complete = TrayPresentation.previewLayout(
        sample, availableWidth: 500, availableHeight: 3000)
      else { throw Failure.assertion }
      try require(complete.text == sample)
      try require(previewFitsTextView(complete))
      guard let limited = TrayPresentation.previewLayout(
        sample, availableWidth: index == 3 ? 140 : 380, availableHeight: 90)
      else { throw Failure.assertion }
      try require(limited.text.hasSuffix("...") && limited.size.height <= 90)
      try require(previewFitsTextView(limited))
    }
    // A screen too small to display even the truncation marker has no panel.
    try require(
      TrayPresentation.previewLayout("too small", availableWidth: 16, availableHeight: 12) == nil)
    let origin = TrayPresentation.previewOrigin(
      screen: NSRect(x: 0, y: 0, width: 1200, height: 800),
      item: NSRect(x: 950, y: 600, width: 200, height: 20), size: NSSize(width: 180, height: 60))
    try require(origin.x == 767 && origin.y == 580)
    try require(TrayPresentation.previewText(Data("first\r\nsecond\r\n".utf8)) == "first\nsecond")
    try require(
      TrayPresentation.previewText(
        TrayPreview(dataType: "rtf", display: Data("  first\r\nsecond\n".utf8), truncated: true))
        == "  first\nsecond\n…")
    try require(
      TrayPresentation.previewText(
        TrayPreview(dataType: "text", display: Data("short".utf8), truncated: false)) == "short")
    try require(
      TrayPresentation.previewText(
        TrayPreview(dataType: "png", display: Data("PNG".utf8), truncated: false)) == nil)
    try require(
      TrayPresentation.truncate(String(repeating: "x", count: 72)) == String(
        repeating: "x", count: 37) + "...")
    try require(
      TrayPresentation.displayWidth(TrayPresentation.truncate(String(repeating: "中", count: 40)))
        == 39)
  }
}
