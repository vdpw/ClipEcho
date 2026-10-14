import Foundation

/// The same ordered pasteboard item/flavor structure stored by the Rust application.
public struct ClipboardEvent: Codable, Equatable, Sendable {
    public var items: [ClipboardItem]
    public init(items: [ClipboardItem]) { self.items = items }
    public func representation(for type: String) -> ClipboardRepresentation? {
        items.lazy.compactMap { $0.representation(for: type) }.first
    }
}

public struct ClipboardItem: Codable, Equatable, Sendable {
    public var dataList: [ClipboardRepresentation]
    public init(dataList: [ClipboardRepresentation]) { self.dataList = dataList }
    public func representation(for type: String) -> ClipboardRepresentation? {
        dataList.first { $0.type == type }
    }
    private enum CodingKeys: String, CodingKey { case dataList = "data_list" }
}

public struct ClipboardRepresentation: Codable, Equatable, Sendable {
    public var type: String
    public var data: Data
    public init(type: String, data: Data) { self.type = type; self.data = data }
    private enum CodingKeys: String, CodingKey { case type, data }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        // serde's Vec<u8> uses a JSON byte array, not Foundation's base64 Data encoding.
        data = Data(try values.decode([UInt8].self, forKey: .data))
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(type, forKey: .type)
        try values.encode(Array(data), forKey: .data)
    }
}

public struct PreparedEvent: Sendable {
    public let contentHash: String
    public let eventData: Data
    public let dataType: String
    public let display: Data
    public let summaryDisplay: Data
    public let summaryTruncated: Bool
    public let compactContentHash: String?
    public let compactDisplay: Data?
    public let sourceBundleID: String?
    public let isRemoteClipboard: Bool
    public let byteCount: Int64
    public let searchText: String
    public let compactSearchText: String
    public let compactMode: Bool
}
