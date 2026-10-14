import AppKit
import ClipEchoCore
import ImageIO

@MainActor
final class HistoryInlinePreviewView: NSView {
  var onHeightChanged: (() -> Void)?
  private let detail: InlineHistoryDetail
  private let language: String
  private var children: [NSView] = []
  private var htmlView: HistoryHTMLPreviewView?
  private var textViewport: NSScrollView?
  override var isFlipped: Bool { true }
  init(detail: InlineHistoryDetail, language: String) {
    self.detail = detail
    self.language = language
    super.init(frame: .zero)
    if let html = detail.html, !html.isEmpty {
      let preview = HistoryHTMLPreviewView(
        html: html, title: L10n.string("formattedPreviewTitle", language: language))
      preview.onHeightChanged = { [weak self] in self?.onHeightChanged?() }
      htmlView = preview
      children = [preview]
    } else if let text = detail.textFallback {
      let scroll = NSScrollView()
      scroll.hasVerticalScroller = true
      scroll.hasHorizontalScroller = true
      scroll.autohidesScrollers = true
      scroll.drawsBackground = true
      scroll.backgroundColor = NSColor(srgbRed: 31 / 255, green: 35 / 255, blue: 41 / 255, alpha: 1)
      let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 280))
      view.isEditable = false
      view.isSelectable = false
      view.string = text
      view.font = .monospacedSystemFont(ofSize: 12.48, weight: .regular)
      view.textColor = NSColor(srgbRed: 217 / 255, green: 226 / 255, blue: 241 / 255, alpha: 1)
      view.backgroundColor = scroll.backgroundColor
      view.textContainerInset = NSSize(width: 16, height: 16)
      view.isHorizontallyResizable = true
      view.isVerticallyResizable = true
      view.textContainer?.widthTracksTextView = false
      view.textContainer?.containerSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
      scroll.documentView = view
      scroll.wantsLayer = true
      scroll.layer?.cornerRadius = 12
      scroll.layer?.borderWidth = 1
      scroll.layer?.borderColor = HistoryVisual.separator(self).cgColor
      textViewport = scroll
      children = [scroll]
    } else if !detail.files.isEmpty {
      for (index, item) in detail.files.enumerated() {
        let name =
          item.name.isEmpty
          ? L10n.format(
            item.type == "folder" ? "folderFallbackName" : "fileFallbackName", language: language,
            args: [String(index + 1)]) : item.name
        let path = item.url.flatMap { URL(string: $0) }.flatMap { ($0 as NSURL).filePathURL?.path }
          .flatMap { $0.hasPrefix("/.file/") ? nil : $0 }
        children.append(
          HistoryFilePreviewView(name: name, path: path, folder: item.type == "folder"))
      }
    } else {
      for segment in detail.segments {
        switch segment {
        case .text(let text):
          let label = HistoryLabel(text)
          label.textColor = HistoryVisual.text(self)
          children.append(label)
        case .image(let data, let label):
          let source = CGImageSourceCreateWithData(data as CFData, nil)
          let properties =
            source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any]
          let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
          let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
          if width > 0, height > 0, width <= 16_384, height <= 16_384,
            Int64(width) * Int64(height) <= 20_000_000, let source,
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(
              source, 0,
              [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1_200,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
          {
            let image = NSImageView(
              image: NSImage(
                cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height)))
            image.imageScaling = .scaleProportionallyUpOrDown
            image.setAccessibilityLabel(
              L10n.format(
                "imageThumbnailAlt", language: language,
                args: [label == "Image" ? L10n.string("image", language: language) : label]))
            image.wantsLayer = true
            image.layer?.cornerRadius = 8
            image.layer?.borderWidth = 1
            image.layer?.borderColor = HistoryVisual.separator(self).cgColor
            image.layer?.backgroundColor = HistoryVisual.controlFill(self).cgColor
            children.append(image)
          } else {
            let placeholder = HistoryImagePlaceholderView()
            children.append(placeholder)
          }
        case .video(let label):
          children.append(
            HistoryVideoPreviewView(
              label: label == "Video" ? L10n.string("video", language: language) : label))
        }
      }
    }
    for child in children { addSubview(child) }
  }
  required init?(coder: NSCoder) { nil }
  func desiredHeight(width: CGFloat) -> CGFloat {
    if let htmlView { return htmlView.previewHeight + 8 }
    if textViewport != nil { return 288 }
    return children.enumerated().reduce(CGFloat(0)) { total, entry in
      total + height(entry.element, width: width)
        + (entry.offset == 0 ? 0 : detail.files.isEmpty ? 6 : 8)
    } + 5
  }
  private func height(_ child: NSView, width: CGFloat) -> CGFloat {
    if let image = child as? NSImageView, let size = image.image?.size {
      return size.height * min(1, width / size.width, 520 / size.width, 520 / size.height)
    }
    if let label = child as? HistoryLabel {
      return HistoryVisual.textHeight(
        label.stringValue, width: width, font: label.font!, lineHeight: 20.16)
    }
    if let file = child as? HistoryFilePreviewView { return file.desiredHeight(width: width) }
    if child is HistoryImagePlaceholderView { return 64 }
    return 66
  }
  override func layout() {
    super.layout()
    var y: CGFloat = 0
    for child in children {
      let h: CGFloat
      if let htmlView {
        h = htmlView.previewHeight
      } else if textViewport != nil {
        h = 280
      } else {
        h = height(child, width: bounds.width)
      }
      var width = bounds.width
      if let image = child as? NSImageView, let size = image.image?.size {
        width = size.width * min(1, width / size.width, 520 / size.width, 520 / size.height)
      } else if child is HistoryImagePlaceholderView {
        width = min(86, width)
      } else if child is HistoryVideoPreviewView {
        width = min(420, width)
      }
      child.frame = NSRect(x: 0, y: y, width: width, height: h)
      child.layoutSubtreeIfNeeded()
      y += h + (detail.files.isEmpty ? 6 : 8)
    }
  }
}

@MainActor
private final class HistoryImagePlaceholderView: NSView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.borderWidth = 1
    layer?.borderColor = HistoryVisual.separator(self).cgColor
    layer?.backgroundColor = HistoryVisual.controlFill(self).cgColor
    setAccessibilityElement(false)
  }
  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class HistoryFilePreviewView: NSView {
  private let name: HistoryLabel
  private let path: HistoryLabel
  private let icon: NSImageView
  override var isFlipped: Bool { true }
  init(name: String, path: String?, folder: Bool) {
    self.name = HistoryLabel(name)
    self.path = HistoryLabel(path ?? "", size: 11.52, lineHeight: 16.704)
    icon = NSImageView(
      image: OriginalIcons.image(folder ? "folder" : "doc")
        ?? NSImage())
    super.init(frame: .zero)
    addSubview(self.name)
    addSubview(self.path)
    addSubview(icon)
    self.name.textColor = HistoryVisual.text(self)
    self.path.textColor = HistoryVisual.secondary(self)
    icon.contentTintColor = HistoryVisual.secondary(self)
  }
  required init?(coder: NSCoder) { nil }
  func desiredHeight(width: CGFloat) -> CGFloat {
    HistoryVisual.textHeight(
      name.stringValue, width: width - 25, font: name.font!, lineHeight: 20.16)
      + (path.stringValue.isEmpty
        ? 0
        : 2
          + HistoryVisual.textHeight(
            path.stringValue, width: width - 25, font: path.font!, lineHeight: 16.704))
  }
  override func layout() {
    super.layout()
    let h = HistoryVisual.textHeight(
      name.stringValue, width: bounds.width - 25, font: name.font!, lineHeight: 20.16)
    icon.frame = NSRect(x: 0, y: 4, width: 18, height: 18)
    name.frame = NSRect(x: 25, y: 0, width: bounds.width - 25, height: h)
    path.frame = NSRect(
      x: 25, y: h + 2, width: bounds.width - 25, height: max(0, bounds.height - h - 2))
  }
}

@MainActor
private final class HistoryVideoPreviewView: NSView {
  private let label: HistoryLabel
  private let icon = NSImageView(
    image: OriginalIcons.image("video") ?? NSImage())
  override var isFlipped: Bool { true }
  init(label: String) {
    self.label = HistoryLabel(label)
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.borderWidth = 1
    layer?.borderColor = HistoryVisual.separator(self).cgColor
    layer?.backgroundColor = HistoryVisual.controlFill(self).cgColor
    addSubview(icon)
    addSubview(self.label)
    self.label.textColor = HistoryVisual.text(self)
    icon.contentTintColor = .white
  }
  required init?(coder: NSCoder) { nil }
  override func layout() {
    super.layout()
    icon.frame = NSRect(x: 22, y: 22, width: 22, height: 22)
    label.frame = NSRect(x: 68, y: 12, width: max(1, bounds.width - 80), height: 42)
  }
  override func draw(_ rect: NSRect) {
    NSColor(srgbRed: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: 0.82).setFill()
    NSBezierPath(ovalIn: NSRect(x: 12, y: 12, width: 42, height: 42)).fill()
  }
  override func mouseDown(with event: NSEvent) {}
}
