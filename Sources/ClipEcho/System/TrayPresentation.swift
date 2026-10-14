import AppKit
import ClipEchoCore

/// Labels and preview layout preserved from the original native tray.
enum TrayPresentation {
  static func string(_ key: String, language: String) -> String {
    let index = L10n.resolve(language) == "zh-CN" ? 1 : L10n.resolve(language) == "zh-TW" ? 2 : 0
    let strings: [String: [String]] = [
      "search": ["Search clipboard…", "搜索剪贴板…", "搜尋剪貼簿…"],
      "history": ["Open history", "打开历史记录", "開啟歷史記錄"],
      "settings": ["Open settings", "打开设置", "開啟設定"],
      "recent": ["Recent clipboard items", "最近的剪贴板项目", "最近的剪貼簿項目"],
      "pinned": ["Pinned", "已固定", "已固定"],
      "empty": ["No clipboard items yet", "暂无剪贴板项目", "尚無剪貼簿項目"],
      "clear": ["Clear unpinned history", "清空未固定的历史记录", "清除未固定的歷史記錄"],
      "quit": ["Quit ClipEcho", "退出 ClipEcho", "結束 ClipEcho"],
      "file": ["File", "文件", "檔案"], "folder": ["Folder", "文件夹", "資料夾"],
      "files": ["Files", "多个文件", "多個檔案"], "folders": ["Folders", "多个文件夹", "多個資料夾"],
      "files and folders": ["Files and folders", "文件和文件夹", "檔案和資料夾"],
      "video": ["Video", "视频", "影片"],
    ]
    return strings[key]?[index] ?? key
  }

  static func label(_ item: HistoryItem, language: String) -> String {
    let full: String
    if let files = EventClassifier.parseFileDisplay(item.display) {
      full = files.items.enumerated().map { index, file in
        let name =
          file.name.isEmpty
          ? "\(string(file.type == "folder" ? "folder" : "file", language: language)) \(index + 1)"
          : file.name
        return "\(file.type == "folder" ? "📁" : "📄") \(name)"
      }.joined(separator: "  ")
    } else {
      let raw = String(decoding: item.display, as: UTF8.self)
      let normalized = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
      let display: String
      if normalized.isEmpty || raw.contains("\u{fffd}") {
        display =
          ["file", "folder", "files", "folders", "files and folders", "video"].contains(
            item.dataType)
          ? string(item.dataType, language: language) : item.dataType.uppercased()
      } else if [
        "video": "Video", "files": "Files", "folders": "Folders",
        "files and folders": "Files and folders",
      ][item.dataType] == normalized {
        display = string(item.dataType, language: language)
      } else {
        display = normalized
      }
      switch item.dataType {
      case "file", "files": full = "📄 \(display)"
      case "folder", "folders": full = "📁 \(display)"
      default: full = display
      }
    }
    return truncate(item.isPinned ? "📌 \(full)" : full)
  }

  static func displayWidth(_ value: String) -> Int {
    value.unicodeScalars.reduce(0) { $0 + menuColumns($1) }
  }
  static func truncate(_ value: String) -> String {
    guard displayWidth(value) > 40 else { return value }
    var result = String.UnicodeScalarView()
    var columns = 0
    for scalar in value.unicodeScalars {
      let width = menuColumns(scalar)
      guard columns + width <= 37 else { break }
      result.append(scalar)
      columns += width
    }
    return String(result) + "..."
  }
  static func needsPreview(title: String, text: String, pinned: Bool) -> Bool {
    let contentTitle = pinned && title.hasPrefix("📌 ") ? String(title.dropFirst(2)) : title
    return contentTitle != text
  }
  static func previewText(_ data: Data) -> String? {
    guard let text = EventCodec.strictUTF8(data) else { return nil }
    var value = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(
      of: "\r", with: "\n")
    while value.hasSuffix("\n") { value.removeLast() }
    return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
  }
  static func previewText(_ preview: TrayPreview) -> String? {
    guard ["text", "rtf", "html"].contains(preview.dataType),
      let text = previewText(preview.display)
    else { return nil }
    return preview.truncated ? text + "\n…" : text
  }

  struct PreviewLayout {
    let size: NSSize
    let text: String
  }
  @MainActor static var previewFont: NSFont {
    .monospacedSystemFont(ofSize: 12, weight: .regular)
  }
  static let previewInsets = NSSize(width: 8, height: 6)

  @MainActor static var previewAttributes: [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.tabStops = []
    paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: previewFont]).width * 4
    return [.font: previewFont, .paragraphStyle: paragraph, .foregroundColor: NSColor.labelColor]
  }

  @MainActor static func previewLayout(
    _ text: String, availableWidth: CGFloat, availableHeight: CGFloat
  ) -> PreviewLayout? {
    let horizontalPadding = previewInsets.width * 2
    let verticalPadding = previewInsets.height * 2
    guard availableWidth > horizontalPadding, availableHeight > verticalPadding else { return nil }
    let attributes = previewAttributes
    let maximumWidth = min(380, availableWidth)
    let minimumWidth = min(180, maximumWidth)
    let naturalWidth = text.split(separator: "\n", omittingEmptySubsequences: false).map {
      (String($0) as NSString).size(withAttributes: attributes).width
    }.max() ?? 0
    let width = min(max(ceil(naturalWidth) + horizontalPadding, minimumWidth), maximumWidth)
    let container = NSTextContainer(
      containerSize: NSSize(width: width - horizontalPadding, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    let manager = NSLayoutManager()
    manager.addTextContainer(container)
    let storage = NSTextStorage()
    storage.addLayoutManager(manager)

    func measure(_ value: String) -> CGFloat {
      storage.setAttributedString(NSAttributedString(string: value, attributes: attributes))
      manager.ensureLayout(for: container)
      return ceil(max(manager.usedRect(for: container).maxY, manager.extraLineFragmentRect.maxY))
    }

    let textHeight = availableHeight - verticalPadding
    var fitted = text
    var height = measure(text)
    if height > textHeight {
      // Use TextKit's actual wrapping and fallback fonts. Counting columns or
      // assuming a 15pt line height clips words, tabs, emoji and CJK text.
      var characterLimit = 0
      manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) {
        rect, _, _, glyphs, stop in
        guard ceil(rect.maxY) <= textHeight else { stop.pointee = true; return }
        characterLimit = NSMaxRange(manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
      }
      guard measure("...") <= textHeight else { return nil }
      // Keep composed characters intact and only search the visible prefix.
      var boundaries = [text.startIndex]
      var characters = 0
      for position in text.indices {
        let next = text.index(after: position)
        characters += text[position..<next].utf16.count
        guard characters <= characterLimit else { break }
        boundaries.append(next)
      }
      var lower = 0
      var upper = boundaries.count - 1
      fitted = "..."
      while lower <= upper {
        let middle = lower + (upper - lower) / 2
        var candidate = String(text[..<boundaries[middle]])
        while candidate.last?.isWhitespace == true { candidate.removeLast() }
        candidate += "..."
        if measure(candidate) <= textHeight {
          fitted = candidate
          lower = middle + 1
        } else {
          upper = middle - 1
        }
      }
      height = measure(fitted)
    }
    return PreviewLayout(
      size: NSSize(width: width, height: max(min(36, availableHeight), height + verticalPadding)),
      text: fitted)
  }
  static func previewOrigin(screen: NSRect, item: NSRect, size: NSSize) -> NSPoint {
    let minimumX = screen.minX + 12
    let maximumX = max(minimumX, screen.maxX - size.width - 12)
    let leftX = item.minX - size.width - 3
    let rightX = item.maxX + 3
    let x =
      leftX >= minimumX
      ? leftX
      : rightX <= maximumX ? rightX : min(max(item.midX - size.width / 2, minimumX), maximumX)
    let minimumY = screen.minY + 12
    let maximumY = max(minimumY, screen.maxY - size.height - 12)
    return NSPoint(x: x, y: min(max(item.midY - size.height / 2, minimumY), maximumY))
  }
  private static func menuColumns(_ scalar: Unicode.Scalar) -> Int {
    let ranges: [ClosedRange<UInt32>] = [
      0x1100...0x115f, 0x2329...0x232a, 0x2e80...0xa4cf, 0xac00...0xd7a3,
      0xf900...0xfaff, 0xfe10...0xfe19, 0xfe30...0xfe6f, 0xff00...0xff60,
      0xffe0...0xffe6, 0x1f300...0x1faff,
    ]
    return ranges.contains { $0.contains(scalar.value) } ? 2 : 1
  }
}
