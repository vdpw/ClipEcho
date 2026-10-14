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

    @Test func testCompactTextNullsPreservesMarkersAndRejectsNonTextAttachments() throws {
        let value = event([("public.utf8-plain-text", Data("hel\0lo\0".utf8)), ("public.html", Data("<p>hello</p>".utf8)), (PasteboardProtocol.remoteType, Data())])
        let prepared = try #require(EventClassifier.prepare(event: value, compactMode: true))
        #expect(prepared.display == Data("hello".utf8))
        #expect(prepared.contentHash == EventClassifier.hash(Data("hello".utf8)))
        #expect(prepared.isRemoteClipboard)
        #expect(prepared.compactContentHash == prepared.contentHash)
        for (type, bytes) in [("public.html", Data("<VIDEO src='x'>".utf8)), ("public.html", Data("<object data='x'></object>".utf8)), ("public.html", Data("<embed src='x'>".utf8)), ("public.rtf", Data(#"{\rtf1\PICT test}"#.utf8)), ("public.png", Data([1]))] {
            #expect(EventClassifier.compactTextEvent(event([("public.utf8-plain-text", Data("hello".utf8)), (type, bytes)])) == nil)
        }
        #expect(EventClassifier.compactTextEvent(event([("public.utf8-plain-text", Data("a\u{fffc}b".utf8))])) == nil)
    }

    @Test func testCompactBrowserSelectionKeepsTextWithHTMLImages() throws {
        let text = "PLOS Biology — Synthetic research title\n合成研究标题的中文翻译\nhttps://example.test/favicon.png\nPubMed\n+1\nSynthetic selected paragraph."
        let html = "<div><a href='https://example.test/paper'><img width='16' height='16' src='https://example.test/favicon.png'>PLOS Biology — Synthetic research title</a><p>合成研究标题的中文翻译</p><span>https://example.test/favicon.png</span><a href='https://example.test/pubmed'>PubMed</a><span>+1</span><p>Synthetic selected paragraph.</p></div>"
        let value = event([
            (EventClassifier.textType, Data(text.utf8)),
            ("public.html", Data(html.utf8)),
            ("org.chromium.internal.source-rfh-token", Data([0, 1, 2])),
            ("org.chromium.source-url", Data("https://example.test/synthetic".utf8)),
            (PasteboardProtocol.sourceType, Data("com.example.synthetic.browser".utf8)),
            (PasteboardProtocol.remoteType, Data()),
        ])
        let compact = try #require(EventClassifier.prepare(event: value, compactMode: true))
        #expect(compact.dataType == "text")
        #expect(compact.display == Data(text.utf8))
        #expect(compact.contentHash == EventClassifier.hash(Data(text.utf8)))
        #expect(compact.sourceBundleID == "com.example.synthetic.browser")
        #expect(compact.isRemoteClipboard)
        let restored = try EventCodec.decode(compact.eventData)
        #expect(restored.items.count == 1)
        #expect(restored.items[0].dataList.map(\.type) == [EventClassifier.textType, PasteboardProtocol.sourceType, PasteboardProtocol.remoteType])
        #expect(restored.representation(for: EventClassifier.textType)?.data == Data(text.utf8))
        let full = try #require(EventClassifier.prepare(event: value, compactMode: false))
        #expect(full.dataType == "html")
        #expect(full.contentHash == EventClassifier.hash(Data(html.utf8)))
        #expect(full.compactContentHash == nil && full.compactDisplay == nil)
        let textOnly = try #require(EventClassifier.prepare(event: restored, compactMode: false))
        #expect(textOnly.dataType == "text" && textOnly.contentHash == compact.contentHash)
        #expect(textOnly.compactContentHash == compact.contentHash && textOnly.compactDisplay == compact.display)
        #expect(try EventCodec.decode(full.eventData) == value)
    }

    @Test func testFullCapturePreservesLegacyCompactMetadataEligibility() throws {
        let text = Data("Synthetic full-mode compatibility".utf8)
        for value in [
            event([(EventClassifier.textType, text)]),
            event([(EventClassifier.textType, text), ("public.html", Data("<p>Synthetic full-mode compatibility</p>".utf8))]),
            event([(EventClassifier.textType, text), ("public.rtf", Data(#"{\rtf1 Synthetic full-mode compatibility}"#.utf8))]),
        ] {
            let full = try #require(EventClassifier.prepare(event: value, compactMode: false))
            #expect(full.compactContentHash == EventClassifier.hash(text) && full.compactDisplay == text)
            #expect(try EventCodec.decode(full.eventData) == value)
        }
        for html in ["<p>Synthetic full-mode compatibility<img src='synthetic.png'></p>", "<picture><img src='synthetic.png'></picture>"] {
            let value = event([(EventClassifier.textType, text), ("public.html", Data(html.utf8))])
            let full = try #require(EventClassifier.prepare(event: value, compactMode: false))
            #expect(full.dataType == "html" && full.contentHash == EventClassifier.hash(Data(html.utf8)))
            #expect(full.compactContentHash == nil && full.compactDisplay == nil)
            #expect(try EventCodec.decode(full.eventData) == value)
        }
    }

    @Test func testCompactHTMLImagesUseValidTextWithoutImageHeuristics() throws {
        let text = Data("Synthetic selected text".utf8)
        for html in ["<IMG src='synthetic.png'>", "<p>Synthetic selected text<img src='synthetic.png'></p>", "<picture><source srcset='synthetic.webp'><img src='synthetic.png'></picture>"] {
            let value = event([(EventClassifier.textType, text), ("public.html", Data(html.utf8))])
            let compact = try #require(EventClassifier.prepare(event: value, compactMode: true))
            #expect(compact.display == text && compact.contentHash == EventClassifier.hash(text))
            #expect(try EventCodec.decode(compact.eventData) == event([(EventClassifier.textType, text)]))
        }
        let imageOnlyHTML = Data("<img src='synthetic.png'>".utf8)
        #expect(EventClassifier.prepare(event: event([("public.html", imageOnlyHTML)]), compactMode: true) == nil)
        for invalidText in [Data(), Data(" \n\t".utf8), Data([255]), Data("Synthetic \u{fffc}".utf8)] {
            #expect(EventClassifier.prepare(event: event([(EventClassifier.textType, invalidText), ("public.html", imageOnlyHTML)]), compactMode: true) == nil)
        }
        for type in ["public.file-url", "public.image", "public.png", "public.tiff", "public.jpeg", "public.jpg", "public.gif", "public.heic", "public.webp", "public.bmp", "public.movie", "public.video"] {
            #expect(EventClassifier.prepare(event: event([(EventClassifier.textType, text), ("public.html", imageOnlyHTML), (type, Data([1]))]), compactMode: true) == nil)
        }
        let multiple = ClipboardEvent(items: [event([(EventClassifier.textType, text)]).items[0], event([(EventClassifier.textType, text)]).items[0]])
        #expect(EventClassifier.prepare(event: multiple, compactMode: true) == nil)
    }

    @Test func testCompactHTMLImageTextStillHonorsPrivacyMarkers() {
        for marker in [PasteboardProtocol.concealedType, PasteboardProtocol.transientType, PasteboardProtocol.autoGeneratedType, "com.agilebits.onepassword"] {
            let value = event([(EventClassifier.textType, Data("Synthetic private browser selection".utf8)), ("public.html", Data("<p>Synthetic text<img src='synthetic.png'></p>".utf8)), (marker, Data())])
            for compactMode in [false, true] {
                #expect(EventClassifier.prepare(event: value, compactMode: compactMode) == nil)
                #expect(EventClassifier.contentHash(event: value, compactMode: compactMode) == nil)
            }
        }
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
