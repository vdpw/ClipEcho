import Foundation

public enum EventCodec {
    public static let maxBlobBytes = 256 * 1024 * 1024
    public static let maxItems = 64
    public static let maxRepresentationsPerItem = 128
    public static let maxTypeBytes = 1024
    private static let magic = Data("CSB1".utf8)

    /// Validates without Foundation's encoding/BOM interpretation; a UTF-8 BOM
    /// and embedded NULs remain content bytes exactly as in Rust String::from_utf8.
    public static func strictUTF8(_ data: Data) -> String? {
        if #available(macOS 15, *) { return String(validating: data, as: UTF8.self) }
        let value = String(decoding: data, as: UTF8.self)
        return data.elementsEqual(value.utf8) ? value : nil
    }

    public enum Failure: Error, LocalizedError, Sendable {
        case invalidHeader, truncated, trailingBytes, invalidType, tooLarge, tooManyItems, tooManyRepresentations
        public var errorDescription: String? {
            switch self {
            case .invalidHeader, .truncated, .trailingBytes, .invalidType: "Clipboard history contains invalid event data."
            case .tooLarge: "Clipboard content exceeds the supported size limit."
            case .tooManyItems: "Clipboard content has too many items."
            case .tooManyRepresentations: "Clipboard content has too many formats."
            }
        }
    }

    public static func encodedSize(_ event: ClipboardEvent) throws -> Int {
        guard event.items.count <= maxItems else { throw Failure.tooManyItems }
        var size = 8
        for item in event.items {
            guard item.dataList.count <= maxRepresentationsPerItem else { throw Failure.tooManyRepresentations }
            size += 4
            for value in item.dataList {
                guard value.type.utf8.count <= maxTypeBytes else { throw Failure.invalidType }
                guard value.data.count <= maxBlobBytes else { throw Failure.tooLarge }
                let increment = 12 + value.type.utf8.count + value.data.count
                guard size <= maxBlobBytes - increment else { throw Failure.tooLarge }
                size += increment
            }
        }
        guard size <= maxBlobBytes else { throw Failure.tooLarge }
        return size
    }

    public static func encode(_ event: ClipboardEvent) throws -> Data {
        let size = try encodedSize(event)
        var output = Data(capacity: size)
        output.append(magic)
        appendInteger(UInt32(event.items.count), to: &output)
        for item in event.items {
            appendInteger(UInt32(item.dataList.count), to: &output)
            for value in item.dataList {
                let type = Data(value.type.utf8)
                appendInteger(UInt32(type.count), to: &output)
                output.append(type)
                appendInteger(UInt64(value.data.count), to: &output)
                output.append(value.data)
            }
        }
        return output
    }

    public static func decode(_ blob: Data) throws -> ClipboardEvent {
        guard blob.count <= maxBlobBytes else { throw Failure.tooLarge }
        // Both v4 binary rows and legacy serde JSON are readable without a migration.
        if blob.first == 123 || blob.first.map({ [9, 10, 13, 32].contains($0) }) == true {
            let event = try JSONDecoder().decode(ClipboardEvent.self, from: blob)
            _ = try encodedSize(event)
            return event
        }
        var reader = Reader(data: blob)
        guard try reader.bytes(4) == magic else { throw Failure.invalidHeader }
        let count = Int(try reader.integer(UInt32.self))
        guard count <= maxItems else { throw Failure.tooManyItems }
        var items: [ClipboardItem] = []
        items.reserveCapacity(count)
        for _ in 0..<count {
            let dataCount = Int(try reader.integer(UInt32.self))
            guard dataCount <= maxRepresentationsPerItem else { throw Failure.tooManyRepresentations }
            var values: [ClipboardRepresentation] = []
            values.reserveCapacity(dataCount)
            for _ in 0..<dataCount {
                let typeCount = Int(try reader.integer(UInt32.self))
                guard typeCount <= maxTypeBytes else { throw Failure.invalidType }
                guard let type = strictUTF8(try reader.bytes(typeCount)) else { throw Failure.invalidType }
                let byteCount = try reader.integer(UInt64.self)
                guard byteCount <= UInt64(maxBlobBytes) else { throw Failure.tooLarge }
                values.append(ClipboardRepresentation(type: type, data: try reader.bytes(Int(byteCount))))
            }
            items.append(ClipboardItem(dataList: values))
        }
        guard reader.offset == blob.count else { throw Failure.trailingBytes }
        return ClipboardEvent(items: items)
    }

    private static func appendInteger<T: FixedWidthInteger>(_ value: T, to output: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { output.append(contentsOf: $0) }
    }

    private struct Reader {
        let data: Data
        var offset = 0
        mutating func bytes(_ count: Int) throws -> Data {
            guard count >= 0, count <= data.count - offset else { throw Failure.truncated }
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }
        mutating func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            let value = try bytes(MemoryLayout<T>.size)
            return value.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
        }
    }
}
