import ClipEchoCore
import Foundation

/// Only bounded preview values are retained. Raw event blobs live in the decode task,
/// never in the twelve-entry presentation cache.
struct InlineHistoryDetail: Sendable {
  struct FileItem: Sendable {
    let type: String
    let name: String
    let url: String?
  }
  enum Segment: Sendable {
    case text(String)
    case image(Data, String)
    case video(String)
  }
  let html: String?
  let textFallback: String?
  let files: [FileItem]
  let segments: [Segment]
  static func build(_ stored: StoredEvent) throws -> InlineHistoryDetail {
    let event = try EventCodec.decode(stored.eventData)
    let fileTypes = ["file", "folder", "files", "folders", "files and folders"]
    if fileTypes.contains(stored.item.dataType) {
      let names = EventClassifier.parseFileDisplay(stored.fullDisplay)?.items ?? []
      var files: [FileItem] = []
      var budget = 8 * 1_024 * 1_024
      for (index, item) in event.items.enumerated().prefix(1_024) {
        guard let value = item.representation(for: "public.file-url") else { continue }
        let url = String(decoding: value.data.prefix(65_536), as: UTF8.self).trimmingCharacters(
          in: .controlCharacters)
        let rawName =
          names.indices.contains(index)
          ? names[index].name : EventClassifier.fileURLDisplayName(url) ?? ""
        let name = String(decoding: rawName.utf8.prefix(65_536), as: UTF8.self)
        let cost = name.utf8.count + url.utf8.count
        guard cost <= budget else { break }
        budget -= cost
        let type =
          names.indices.contains(index) ? names[index].type : url.hasSuffix("/") ? "folder" : "file"
        files.append(FileItem(type: type, name: name, url: url))
      }
      return InlineHistoryDetail(html: nil, textFallback: nil, files: files, segments: [])
    }
    let rawHTML = event.representation(for: "public.html")
    let html = rawHTML.flatMap { representation -> String? in
      guard representation.data.count <= 2 * 1_024 * 1_024 else { return nil }
      let value = String(decoding: representation.data, as: UTF8.self).replacingOccurrences(
        of: "\0", with: ""
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      return value.isEmpty ? nil : value
    }
    let plain = event.representation(for: EventClassifier.textType).map {
      String(decoding: $0.data.prefix(1_024 * 1_024), as: UTF8.self).replacingOccurrences(
        of: "\0", with: "")
    }
    var images: [Segment] = []
    var imageBudget =
      8 * 1_024 * 1_024 - (html?.utf8.count ?? 0)
      - (rawHTML != nil && html == nil ? plain?.utf8.count ?? 0 : 0)
    for item in event.items.prefix(32) {
      if let value = item.representation(for: "public.png"), value.data.count <= 4 * 1_024 * 1_024 {
        guard value.data.count <= imageBudget else { break }
        images.append(.image(value.data, "Image"))
        imageBudget -= value.data.count
        continue
      }
      if let value = item.representation(for: "public.file-url"),
        let url = URL(
          string: String(decoding: value.data, as: UTF8.self).trimmingCharacters(
            in: .controlCharacters)), url.isFileURL,
        ["png", "jpg", "jpeg", "gif", "webp", "bmp"].contains(url.pathExtension.lowercased()),
        let handle = try? FileHandle(forReadingFrom: url)
      {
        defer { try? handle.close() }
        if let bytes = try? handle.read(upToCount: 4 * 1_024 * 1_024 + 1), !bytes.isEmpty,
          bytes.count <= 4 * 1_024 * 1_024
        {
          guard bytes.count <= imageBudget else { break }
          images.append(.image(bytes, url.lastPathComponent))
          imageBudget -= bytes.count
        }
      }
    }
    var segments: [Segment] = []
    if let plain, plain.contains("\u{fffc}"), !images.isEmpty {
      var index = 0
      let parts = plain.components(separatedBy: "\u{fffc}")
      for (position, part) in parts.enumerated() {
        if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          segments.append(.text(part))
        }
        if position < parts.count - 1, index < images.count {
          segments.append(images[index])
          index += 1
        }
        if segments.count >= 32 { break }
      }
    } else if event.items.count == 1 {
      segments = images
    }
    if segments.isEmpty, stored.item.dataType == "video" {
      segments = [.video(String(decoding: stored.fullDisplay, as: UTF8.self))]
    }
    var budget =
      8 * 1_024 * 1_024 - (html?.utf8.count ?? 0)
      - (rawHTML != nil && html == nil ? plain?.utf8.count ?? 0 : 0)
    segments = Array(segments.prefix(32)).filter { segment in
      let size: Int
      switch segment {
      case .text(let text): size = text.utf8.count
      case .image(let data, _): size = data.count
      case .video(let label): size = label.utf8.count
      }
      guard size <= budget else { return false }
      budget -= size
      return true
    }
    return InlineHistoryDetail(
      html: html, textFallback: rawHTML != nil && html == nil ? plain : nil, files: [],
      segments: segments)
  }
  func richLabel(language: String) -> String? {
    guard html == nil, textFallback == nil, !segments.isEmpty else { return nil }
    let hasText = segments.contains {
      if case .text = $0 { return true }
      return false
    }
    let hasImage = segments.contains {
      if case .image = $0 { return true }
      return false
    }
    let hasVideo = segments.contains {
      if case .video = $0 { return true }
      return false
    }
    return L10n.string(
      hasText && hasImage ? "textAndImage" : hasVideo ? "video" : hasImage ? "image" : "text",
      language: language)
  }
}

extension InlineHistoryDetail {
  var hasContent: Bool { html != nil || textFallback != nil || !files.isEmpty || !segments.isEmpty }
}
