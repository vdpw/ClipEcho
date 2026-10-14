import Foundation
import Testing
@testable import ClipEchoCore

@Suite struct CodecTests {
    private func event(_ values: [(String, Data)]) -> ClipboardEvent {
        ClipboardEvent(items: [ClipboardItem(dataList: values.map { ClipboardRepresentation(type: $0.0, data: $0.1) })])
    }

    @Test func testBinaryFixtureMatchesRustLittleEndianCodec() throws {
        // Independent CSB1 wire fixture: magic, UInt32 item/flavor/type counts,
        // 22 UTF-8 type bytes, UInt64 payload length, then the two bytes "hi".
        let fixture = Data([
            0x43, 0x53, 0x42, 0x31,
            0x01, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00,
            0x16, 0x00, 0x00, 0x00,
            0x70, 0x75, 0x62, 0x6c, 0x69, 0x63, 0x2e, 0x75, 0x74, 0x66, 0x38,
            0x2d, 0x70, 0x6c, 0x61, 0x69, 0x6e, 0x2d, 0x74, 0x65, 0x78, 0x74,
            0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x68, 0x69,
        ])
        let value = event([("public.utf8-plain-text", Data("hi".utf8))])
        #expect(try EventCodec.encode(value) == fixture)
        #expect(try EventCodec.decode(fixture) == value)
        #expect(try EventCodec.encodedSize(value) == fixture.count)
    }

    @Test func testLegacySerdeByteArrayDecodesAndRoundTripsBinary() throws {
        let legacy = Data(#"{"items":[{"data_list":[{"type":"public.utf8-plain-text","data":[104,105]},{"type":"public.png","data":[0,1,255]}]}]}"#.utf8)
        let decoded = try EventCodec.decode(legacy)
        #expect(decoded.items[0].dataList[1].data == Data([0,1,255]))
        #expect(try EventCodec.decode(EventCodec.encode(decoded)) == decoded)
        let reencoded = try JSONEncoder().encode(decoded)
        #expect(String(decoding: reencoded, as: UTF8.self).contains("[104,105]"))
    }

    @Test func testMalformedCountsAndLengthsFailBeforeAllocation() throws {
        for data in [
            Data([67,83,66,49,65,0,0,0]),
            Data([67,83,66,49,1,0,0,0,129,0,0,0]),
            Data([67,83,66,49,1,0,0,0,1,0,0,0,1,4,0,0]),
            Data([67,83,66,49,1,0,0,0,1,0,0,0,1,0,0,0,120,1,0,0,16,0,0,0,0]),
            Data([67,83,66,49,1,0,0,0,1,0,0,0,1,0,0,0,255]),
        ] { #expect(throws: (any Error).self) { try EventCodec.decode(data) } }
        let encoded = try EventCodec.encode(event([("public.png", Data([0,1,255]))]))
        #expect(throws: (any Error).self) { try EventCodec.decode(encoded.dropLast()) }
        #expect(throws: (any Error).self) { try EventCodec.decode(encoded + Data([0])) }
    }

    @Test func testNormalizedIdentityPriorityMatchesExistingRows() {
        let text = Data("hello".utf8)
        let plain = event([("public.utf8-plain-text", text)])
        let hash = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        #expect(EventClassifier.classify(event: plain)?.contentHash == hash)
        let rich = event([("public.utf8-plain-text", text), ("public.html", Data("HTML".utf8)), ("public.png", Data([1])), ("public.rtf", Data("RTF".utf8)), (PasteboardProtocol.sourceType, Data("com.example".utf8))])
        #expect(EventClassifier.classify(event: rich)?.dataType == "rtf")
        #expect(EventClassifier.classify(event: rich)?.contentHash == EventClassifier.hash(Data("RTF".utf8)))
        let withSource = event([("public.utf8-plain-text", text), (PasteboardProtocol.sourceType, Data("anything".utf8)), (PasteboardProtocol.remoteType, Data([255]))])
        #expect(EventClassifier.classify(event: withSource)?.contentHash == hash)
    }

    @Test func testCompactTextNullsPreservesMarkersAndRejectsInlineMedia() throws {
        let value = event([("public.utf8-plain-text", Data("hel\0lo\0".utf8)), ("public.html", Data("<p>hello</p>".utf8)), (PasteboardProtocol.remoteType, Data())])
        let prepared = try #require(EventClassifier.prepare(event: value, compactMode: true))
        #expect(prepared.display == Data("hello".utf8))
        #expect(prepared.contentHash == EventClassifier.hash(Data("hello".utf8)))
        #expect(prepared.isRemoteClipboard)
        #expect(prepared.compactContentHash == prepared.contentHash)
        for (type, bytes) in [("public.html", Data("<IMG src='x'>".utf8)), ("public.rtf", Data(#"{\rtf1\PICT test}"#.utf8)), ("public.png", Data([1]))] {
            #expect(EventClassifier.compactTextEvent(event([("public.utf8-plain-text", Data("hello".utf8)), (type, bytes)])) == nil)
        }
        #expect(EventClassifier.compactTextEvent(event([("public.utf8-plain-text", Data("a\u{fffc}b".utf8))])) == nil)
    }

    @Test func testResourceLimitCountsBinaryOverheadAndCompleteFallback() throws {
        let empty = event([("public.utf8-plain-text", Data())])
        let limit: Int64 = 1024 * 1024
        let overhead = try EventCodec.encodedSize(empty)
        let exact = event([("public.utf8-plain-text", Data(repeating: 120, count: Int(limit) - overhead))])
        #expect(EventClassifier.prepare(event: exact, compactMode: false, maxEventBytes: limit) != nil)
        let above = event([("public.utf8-plain-text", Data(repeating: 120, count: Int(limit) - overhead + 1))])
        #expect(EventClassifier.prepare(event: above, compactMode: false, maxEventBytes: limit) == nil)
        let rich = event([("public.utf8-plain-text", Data("small fallback".utf8)), ("public.html", Data(repeating: 120, count: Int(limit))), (PasteboardProtocol.sourceType, Data("com.example".utf8))])
        let fallback = try #require(EventClassifier.prepare(event: rich, compactMode: false, maxEventBytes: limit))
        #expect(fallback.dataType == "text")
        #expect(fallback.sourceBundleID == "com.example")
        #expect(EventClassifier.prepare(event: event([("public.file-url", Data(repeating: 120, count: EventClassifier.maxFileURLBytes + 1))]), compactMode: false) == nil)
    }

    @Test func testMultiFileIdentityAndDisplayMatchSerdeFormat() throws {
        let value = ClipboardEvent(items: [
            ClipboardItem(dataList: [ClipboardRepresentation(type: "public.file-url", data: Data("file:///tmp/one.txt".utf8)), ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("/tmp/one.txt\r/tmp/Two Folder".utf8))]),
            ClipboardItem(dataList: [ClipboardRepresentation(type: "public.file-url", data: Data("file:///tmp/Two%20Folder/".utf8))]),
        ])
        let prepared = try #require(EventClassifier.prepare(event: value, compactMode: false))
        #expect(prepared.contentHash == EventClassifier.hash(Data("file:///tmp/one.txtfile:///tmp/Two%20Folder/".utf8)))
        #expect(prepared.dataType == "files and folders")
        #expect(String(decoding: prepared.display, as: UTF8.self) == #"{"format":"copy_stack.file-items.v1","items":[{"type":"file","name":"one.txt"},{"type":"folder","name":"Two Folder"}]}"#)
        #expect(prepared.searchText == "one.txt\nTwo Folder")
    }

    @Test func testDisplayNormalizationAndAccountingStayBounded() throws {
        let text = "  alpha\0beta\t \n gamma\u{2003}delta  "
        let value = event([("public.rtf", Data("RTF".utf8)), ("public.utf8-plain-text", Data(text.utf8))])
        #expect(EventClassifier.classify(event: value)?.display == Data("alphabeta gamma delta".utf8))
        let long = event([("public.utf8-plain-text", Data(String(repeating: "界 ", count: 1000).utf8))])
        let prepared = try #require(EventClassifier.prepare(event: long, compactMode: false))
        #expect(prepared.summaryDisplay.count <= 512)
        #expect(prepared.summaryTruncated)
        #expect(String(data: prepared.summaryDisplay, encoding: .utf8) != nil)
        let accounted = prepared.eventData.count + prepared.display.count + prepared.summaryDisplay.count + (prepared.compactDisplay?.count ?? 0)
        #expect(prepared.byteCount == Int64(accounted))
    }
}
