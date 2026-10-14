import CryptoKit
import Foundation

public struct ClassifiedEvent: Equatable, Sendable {
    public let contentHash: String
    public let dataType: String
    public let display: Data
}

public struct FileDisplay: Codable, Equatable, Sendable {
    public var format: String
    public var items: [FileDisplayItem]
}

public struct FileDisplayItem: Codable, Equatable, Sendable {
    public var type: String
    public var name: String
}

public enum EventClassifier {
    public static let maxDisplayBytes = 1024 * 1024
    public static let maxSummaryBytes = 512
    public static let maxFileURLBytes = 64 * 1024
    public static let fileDisplayFormat = "copy_stack.file-items.v1"
    public static let textType = "public.utf8-plain-text"

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Same representation priority and hash bytes as Rust classifier metadata v4.
    public static func classify(event: ClipboardEvent) -> ClassifiedEvent? {
        for (type, label) in [("public.rtf", "rtf"), ("public.png", "png"), ("public.html", "html")] {
            if let value = event.representation(for: type) {
                let display: Data
                if label == "png" { display = value.data.count <= maxDisplayBytes ? value.data : Data("PNG".utf8) }
                else { display = Data((normalizedUTF8Display(event) ?? label.uppercased()).utf8) }
                return ClassifiedEvent(contentHash: hash(value.data), dataType: label, display: display)
            }
        }
        if event.items.count > 1 {
            let urls = event.items.compactMap { $0.representation(for: "public.file-url") }
            if urls.count == event.items.count {
                let folders = urls.filter { String(decoding: $0.data, as: UTF8.self).hasSuffix("/") }.count
                let type = folders == 0 ? "files" : folders == urls.count ? "folders" : "files and folders"
                var hasher = SHA256()
                urls.forEach { hasher.update(data: $0.data) }
                let contentHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                let names = fileDisplayNames(event)
                let items = event.items.enumerated().compactMap { index, item -> FileDisplayItem? in
                    let name = index < names.count ? names[index] : nil
                    return fileDisplayItem(item, displayName: name)
                }
                return ClassifiedEvent(contentHash: contentHash, dataType: type, display: encodeFileDisplay(items))
            }
        }
        guard event.items.count == 1, let item = event.items.first else { return nil }
        if let value = item.representation(for: "public.file-url") {
            let url = String(decoding: value.data, as: UTF8.self)
            let ext = fileURLExtension(url)
            let videos = ["mov", "mp4", "m4v", "avi", "webm", "mkv", "mpeg", "mpg"]
            if let ext, videos.contains(ext) {
                return ClassifiedEvent(contentHash: hash(value.data), dataType: "video", display: Data(normalizeDisplay(fileURLDisplayName(url) ?? "Video").utf8))
            }
            let images = ["png", "jpg", "jpeg", "gif", "webp", "tiff", "tif", "bmp", "heic", "heif"]
            if !url.hasSuffix("/") {
                let imageType = ext.flatMap { images.contains($0) ? $0 : nil }
                    ?? (item.representation(for: "public.tiff")?.data.isEmpty == false ? "tiff" : nil)
                if let imageType {
                    return ClassifiedEvent(contentHash: hash(value.data), dataType: imageType, display: Data(imageType.uppercased().utf8))
                }
            }
            let type = url.hasSuffix("/") ? "folder" : "file"
            let display = encodeFileDisplay([fileDisplayItemForURL(type: type, url: url, displayName: fileDisplayNames(event).first)])
            return ClassifiedEvent(contentHash: hash(value.data), dataType: type, display: display)
        }
        guard let value = item.representation(for: textType) else { return nil }
        let display: Data
        if value.data.count <= maxDisplayBytes { display = value.data }
        else if let text = EventCodec.strictUTF8(value.data) { display = boundedUTF8(text, maxBytes: maxDisplayBytes).0 }
        else { display = Data("text".utf8) }
        return ClassifiedEvent(contentHash: hash(value.data), dataType: "text", display: display)
    }

    public static func contentHash(event: ClipboardEvent, compactMode: Bool) -> String? {
        guard PasteboardProtocol.assess(event).shouldRecord else { return nil }
        if compactMode {
            return compactTextEvent(event).flatMap { classify(event: $0)?.contentHash }
        }
        return classify(event: event)?.contentHash
    }

    public static func compactTextEvent(_ event: ClipboardEvent) -> ClipboardEvent? {
        compactTextEvent(event, allowInlineHTMLImages: true)
    }

    private static func compactTextEvent(_ event: ClipboardEvent, allowInlineHTMLImages: Bool) -> ClipboardEvent? {
        guard event.items.count == 1, !containsAttachment(event, allowInlineHTMLImages: allowInlineHTMLImages),
              let text = event.representation(for: textType).flatMap({ EventCodec.strictUTF8($0.data) }),
              !text.contains("\u{fffc}") else { return nil }
        let value = text.replacingOccurrences(of: "\0", with: "")
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var dataList = [ClipboardRepresentation(type: textType, data: Data(value.utf8))]
        for type in [PasteboardProtocol.sourceType, PasteboardProtocol.remoteType] {
            if let marker = event.representation(for: type) { dataList.append(marker) }
        }
        return ClipboardEvent(items: [ClipboardItem(dataList: dataList)])
    }

    public static func prepare(event: ClipboardEvent, compactMode: Bool, maxEventBytes: Int64 = 32 * 1024 * 1024) -> PreparedEvent? {
        let assessment = PasteboardProtocol.assess(event)
        guard assessment.shouldRecord, let bounded = prepareResourceEvent(event, maxEventBytes: maxEventBytes) else { return nil }
        let prepared: ClipboardEvent
        if compactMode {
            guard let compact = compactTextEvent(bounded) else { return nil }
            prepared = compact
        } else { prepared = bounded }
        guard let classified = classify(event: prepared), let encoded = try? EventCodec.encode(prepared) else { return nil }
        let display = boundedPersistedDisplay(classified.dataType, classified.display)
        let summary = boundedSummaryDisplay(classified.dataType, display)
        // Full rows retain the legacy compact eligibility because older clients
        // restore their raw payload. New compact captures encode text only.
        let compact = compactMode ? classified : compactTextEvent(bounded, allowInlineHTMLImages: false).flatMap { classify(event: $0) }
        let compactDisplay = compact.map { boundedPersistedDisplay($0.dataType, $0.display) }
        let source = assessment.sourceBundleID.flatMap { $0.utf8.count <= 255 ? $0 : nil }
        let byteCount = encoded.count + display.count + summary.0.count + (compactDisplay?.count ?? 0) + (source?.utf8.count ?? 0)
        return PreparedEvent(contentHash: classified.contentHash, eventData: encoded, dataType: classified.dataType,
                             display: display, summaryDisplay: summary.0, summaryTruncated: summary.1,
                             compactContentHash: compact?.contentHash, compactDisplay: compactDisplay,
                             sourceBundleID: source, isRemoteClipboard: assessment.isRemoteClipboard, byteCount: Int64(byteCount),
                             searchText: searchableText(dataType: classified.dataType, display: display),
                             compactSearchText: compactDisplay.map { searchablePlainText($0) } ?? "", compactMode: compactMode)
    }

    public static func prepareResourceEvent(_ event: ClipboardEvent, maxEventBytes: Int64) -> ClipboardEvent? {
        let limit = Int(max(0, min(Int64(EventCodec.maxBlobBytes), maxEventBytes)))
        let size = (try? EventCodec.encodedSize(event)) ?? EventCodec.maxBlobBytes + 1
        let oversized = size > limit || event.items.flatMap(\.dataList).contains { value in
            let ceiling = value.type == "public.file-url" ? maxFileURLBytes : limit
            return value.data.count > ceiling
        }
        if !oversized { return event }
        guard let text = event.representation(for: textType), text.data.count <= limit,
              let value = EventCodec.strictUTF8(text.data),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.contains("\u{fffc}") else { return nil }
        let markers = event.items.flatMap(\.dataList).filter { $0.type == PasteboardProtocol.sourceType || $0.type == PasteboardProtocol.remoteType }
        let fallback = ClipboardEvent(items: [ClipboardItem(dataList: [text] + markers)])
        guard let fallbackSize = try? EventCodec.encodedSize(fallback), fallbackSize <= limit else { return nil }
        return fallback
    }

    public static func parseFileDisplay(_ data: Data) -> FileDisplay? {
        guard let display = try? JSONDecoder().decode(FileDisplay.self, from: data), display.format == fileDisplayFormat else { return nil }
        return display
    }

    public static func fileURLPath(_ url: String) -> String? {
        let stripped = stripURLSuffix(url)
        guard stripped.hasPrefix("file://") else { return nil }
        return percentDecode(String(stripped.dropFirst(7)))
    }

    public static func fileURLDisplayName(_ url: String) -> String? {
        var path = stripURLSuffix(url)
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasPrefix("file://") { path = String(path.dropFirst(7)) }
        return pathDisplayName(percentDecode(path))
    }

    public static func searchableText(dataType: String, display: Data) -> String {
        if let files = parseFileDisplay(display) { return files.items.map(\.name).joined(separator: "\n") }
        return ["text", "rtf", "html", "video"].contains(dataType) ? searchablePlainText(display) : ""
    }

    public static func searchablePlainText(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\0", with: "")
    }

    public static func boundedUTF8(_ value: String, maxBytes: Int) -> (Data, Bool) {
        let data = Data(value.utf8)
        if data.count <= maxBytes { return (data, false) }
        var end = max(0, maxBytes - 3)
        while end > 0 && data[end] & 0xc0 == 0x80 { end -= 1 }
        var output = Data(data.prefix(end))
        if maxBytes >= 3 { output.append(Data("...".utf8)) }
        return (output, true)
    }

    private static func boundedPersistedDisplay(_ type: String, _ data: Data) -> Data {
        guard data.count > maxDisplayBytes else { return data }
        if let text = EventCodec.strictUTF8(data) { return boundedUTF8(text, maxBytes: maxDisplayBytes).0 }
        let label = ["files": "Files", "folders": "Folders", "files and folders": "Files and folders"][type] ?? type
        return Data(label.utf8)
    }

    private static func boundedSummaryDisplay(_ type: String, _ data: Data) -> (Data, Bool) {
        if let files = parseFileDisplay(data) {
            var items: [FileDisplayItem] = []
            var changed = data.count > maxSummaryBytes
            for file in files.items {
                let (name, truncated) = boundedUTF8(file.name, maxBytes: maxSummaryBytes / 3)
                changed = changed || truncated
                let item = FileDisplayItem(type: file.type, name: String(decoding: name, as: UTF8.self))
                if encodeFileDisplay(items + [item]).count > maxSummaryBytes { changed = true; break }
                items.append(item)
            }
            changed = changed || items.count != files.items.count
            return (encodeFileDisplay(items), changed)
        }
        if let value = EventCodec.strictUTF8(data) { return boundedUTF8(value, maxBytes: maxSummaryBytes) }
        return (Data((type.isEmpty ? "CLIPBOARD ITEM" : type.uppercased()).utf8), true)
    }

    private static func encodeFileDisplay(_ items: [FileDisplayItem]) -> Data {
        // Fixed field order and slash escaping match serde_json, including byte accounting.
        let entries = items.map { "{\"type\":\(jsonString($0.type)),\"name\":\(jsonString($0.name))}" }.joined(separator: ",")
        return Data("{\"format\":\(jsonString(fileDisplayFormat)),\"items\":[\(entries)]}".utf8)
    }

    private static func jsonString(_ value: String) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: (try? encoder.encode(value)) ?? Data("\"\"".utf8), as: UTF8.self)
    }

    private static func fileDisplayItem(_ item: ClipboardItem, displayName: String?) -> FileDisplayItem? {
        guard let value = item.representation(for: "public.file-url") else { return nil }
        let url = String(decoding: value.data, as: UTF8.self)
        let ownName = item.representation(for: textType).flatMap { splitFileNames(String(decoding: $0.data, as: UTF8.self)).first }
        return fileDisplayItemForURL(type: url.hasSuffix("/") ? "folder" : "file", url: url, displayName: displayName ?? ownName)
    }

    private static func fileDisplayItemForURL(type: String, url: String, displayName: String?) -> FileDisplayItem {
        let urlName = fileURLDisplayName(url).flatMap { isReferenceName($0) ? nil : $0 }
        return FileDisplayItem(type: type, name: displayName ?? urlName ?? "")
    }

    private static func fileDisplayNames(_ event: ClipboardEvent) -> [String] {
        event.representation(for: textType).map { splitFileNames(String(decoding: $0.data, as: UTF8.self)) } ?? []
    }

    private static func splitFileNames(_ value: String) -> [String] {
        value.split(separator: "\r", omittingEmptySubsequences: false).compactMap { part in
            let trimmed = String(part).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
            guard !trimmed.isEmpty else { return nil }
            let words = trimmed.split(whereSeparator: \.isWhitespace)
            if words.count == 2, UInt(words[0]) != nil, ["file", "files", "folder", "folders", "item", "items"].contains(words[1].lowercased()) { return nil }
            let name = pathDisplayName(trimmed) ?? trimmed
            return isReferenceName(name) ? nil : name
        }
    }

    private static func isReferenceName(_ name: String) -> Bool { name == ".file" || name.hasPrefix("id=") }
    private static func pathDisplayName(_ path: String) -> String? { path.split(separator: "/").last.map(String.init) }
    private static func stripURLSuffix(_ url: String) -> String { String(url.prefix { $0 != "?" && $0 != "#" }) }
    private static func fileURLExtension(_ url: String) -> String? {
        var path = stripURLSuffix(url)
        while path.hasSuffix("/") { path.removeLast() }
        guard let name = path.split(separator: "/").last, let dot = name.lastIndex(of: ".") else { return nil }
        let ext = name[name.index(after: dot)...]
        return ext.isEmpty ? nil : ext.lowercased()
    }

    private static func percentDecode(_ value: String) -> String {
        let bytes = Array(value.utf8); var output: [UInt8] = []; var index = 0
        while index < bytes.count {
            if bytes[index] == 37, index + 2 < bytes.count,
               let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
                output.append(high * 16 + low); index += 3
            } else { output.append(bytes[index]); index += 1 }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte { case 48...57: byte - 48; case 65...70: byte - 55; case 97...102: byte - 87; default: nil }
    }

    private static func normalizedUTF8Display(_ event: ClipboardEvent) -> String? {
        for item in event.items {
            if let value = item.representation(for: textType) {
                let text = normalizeDisplay(String(decoding: value.data, as: UTF8.self))
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    private static func normalizeDisplay(_ value: String) -> String {
        var output = String.UnicodeScalarView(); var pendingSpace = false; var bytes = 0
        for scalar in value.unicodeScalars {
            if scalar.value == 0 { continue }
            if scalar.properties.isWhitespace { pendingSpace = !output.isEmpty; continue }
            if pendingSpace { output.append(" "); bytes += 1; pendingSpace = false }
            output.append(scalar); bytes += scalar.utf8.count
            if bytes > maxDisplayBytes { return String(decoding: boundedUTF8(String(output), maxBytes: maxDisplayBytes).0, as: UTF8.self) }
        }
        return String(output)
    }

    private static func containsAttachment(_ event: ClipboardEvent, allowInlineHTMLImages: Bool) -> Bool {
        let htmlAttachments = allowInlineHTMLImages ? ["video", "object", "embed"] : ["img", "picture", "video", "object", "embed"]
        let attachments = ["public.file-url", "public.image", "public.png", "public.tiff", "public.jpeg", "public.jpg", "public.gif", "public.heic", "public.webp", "public.bmp", "public.movie", "public.video"]
        return event.items.flatMap(\.dataList).contains { value in
            let type = value.type.lowercased()
            if attachments.contains(type) { return true }
            if type == "public.html" { return hasPrefixAfterDelimiter(value.data, delimiter: 60, prefixes: htmlAttachments) }
            if type == "public.rtf" { return hasPrefixAfterDelimiter(value.data, delimiter: 92, prefixes: ["pict"]) }
            return false
        }
    }

    private static func hasPrefixAfterDelimiter(_ data: Data, delimiter: UInt8, prefixes: [String]) -> Bool {
        let patterns = prefixes.map { Array($0.utf8) }
        for offset in data.indices where data[offset] == delimiter {
            let start = offset + 1
            for pattern in patterns where start + pattern.count <= data.count {
                var matches = true
                for index in pattern.indices {
                    let byte = data[start + index]
                    if (65...90).contains(byte) ? byte + 32 != pattern[index] : byte != pattern[index] { matches = false; break }
                }
                if matches { return true }
            }
        }
        return false
    }
}
