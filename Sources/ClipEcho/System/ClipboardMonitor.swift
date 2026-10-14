import AppKit
import ClipEchoCore

@MainActor
final class ClipboardMonitor {
    private let pasteboard: NSPasteboard
    private let settingsProvider: () -> AppSettings
    private let onCapture: (PreparedEvent) -> Void
    private let onError: (any Error) -> Void
    private var timer: Timer?
    private var observedChangeCount: Int
    private var pendingReadChangeCount: Int?
    private var pendingReadAttempts = 0
    // Producers can declare a generation before its promised public body is ready.
    // Retry for at most 2.4 seconds at the normal 300 ms polling cadence.
    static let maxReadAttempts = 8
    private var suppression: RestoreSuppression?
    private let processor = CaptureProcessor()
    private var generation = 0
    private var nextSequence = 0
    private var deliverySequence = 0
    private var completed: [Int: CaptureResult] = [:]

    enum Failure: Error, LocalizedError {
        case tooLarge, cannotRestore, writeFailed, pasteboardChanged
        var errorDescription: String? {
            switch self {
            case .tooLarge: "Clipboard content exceeds the configured size limit."
            case .cannotRestore: "This clipboard item cannot be restored in the current mode."
            case .writeFailed: "The clipboard could not be updated."
            case .pasteboardChanged: "Clipboard content changed while it was being read."
            }
        }
    }

    init(pasteboard: NSPasteboard = .general,
         settingsProvider: @escaping () -> AppSettings,
         onCapture: @escaping (PreparedEvent) -> Void,
         onError: @escaping (any Error) -> Void) {
        self.pasteboard = pasteboard
        self.settingsProvider = settingsProvider
        self.onCapture = onCapture
        self.onError = onError
        // Never retrieve or retain the user's pre-launch clipboard body.
        observedChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        observedChangeCount = pasteboard.changeCount
        pendingReadChangeCount = nil; pendingReadAttempts = 0
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.pollNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate(); timer = nil; suppression = nil
        pendingReadChangeCount = nil; pendingReadAttempts = 0
        generation += 1; nextSequence = 0; deliverySequence = 0; completed.removeAll()
    }

    func pollNow() async {
        // Backpressure: never accumulate an unbounded queue of large clipboard
        // bodies. Leave the newest generation unread until a slot is available.
        guard nextSequence - deliverySequence < 2 else { return }
        let count = pasteboard.changeCount
        guard count != observedChangeCount else { return }
        if pendingReadChangeCount != count {
            pendingReadChangeCount = count; pendingReadAttempts = 0
        }
        if let pending = suppression {
            suppression = nil
            if pending.suppresses(changeCount: count) {
                finishRead(changeCount: count)
                return
            }
        }
        do {
            let settings = settingsProvider()
            let finalAttempt = pendingReadAttempts + 1 >= Self.maxReadAttempts
            let input: CaptureInput
            switch try readEvent(expectedChangeCount: count, compactMode: settings.compactMode,
                                allowIncompleteData: finalAttempt) {
            case .ignored:
                finishRead(changeCount: count)
                return
            case .pending:
                pendingReadAttempts += 1
                if finalAttempt { finishRead(changeCount: count) }
                return
            case .ready(let ready): input = ready
            }
            // Consume only a completed read, before awaiting the processing actor,
            // so another poll cannot enqueue the same generation twice.
            finishRead(changeCount: count)
            let sequence = nextSequence; nextSequence += 1
            let capturedGeneration = generation
            let result = await processor.prepare(input, compactMode: settings.compactMode, maxEventBytes: settings.maxEventBytes)
            guard generation == capturedGeneration else { return }
            completed[sequence] = result
            // Independent polls may resume out of order; deliver captures in
            // observed pasteboard order even when larger events take longer.
            while let ready = completed.removeValue(forKey: deliverySequence) {
                deliverySequence += 1
                if let prepared = ready.prepared { onCapture(prepared) }
                else if ready.resourceRejected { onError(Failure.tooLarge) }
            }
        } catch Failure.pasteboardChanged {
            // A newer generation is picked up on the next poll, never a mixed event.
        } catch {
            finishRead(changeCount: count)
            onError(error)
        }
    }

    private func finishRead(changeCount: Int) {
        observedChangeCount = changeCount
        pendingReadChangeCount = nil; pendingReadAttempts = 0
    }

    func restore(_ stored: StoredEvent, compactMode: Bool) async throws {
        let event = try await Task.detached(priority: .userInitiated) {
            var event = try EventCodec.decode(stored.eventData)
            guard PasteboardProtocol.assess(event).shouldRecord else { throw Failure.cannotRestore }
            if compactMode {
                guard let compact = EventClassifier.compactTextEvent(event) else { throw Failure.cannotRestore }
                event = compact
            }
            event = try PasteboardProtocol.prepareForRestore(event, sourceBundleID: stored.sourceBundleID, isRemoteClipboard: stored.isRemoteClipboard)
            _ = try EventCodec.encodedSize(event)
            return event
        }.value
        let objects = try event.items.map { item in
            let object = NSPasteboardItem()
            for value in item.dataList {
                guard object.setData(value.data, forType: NSPasteboard.PasteboardType(value.type)) else { throw Failure.writeFailed }
            }
            return object
        }
        guard !objects.isEmpty else { throw Failure.cannotRestore }
        pendingReadChangeCount = nil; pendingReadAttempts = 0
        pasteboard.clearContents()
        let success = pasteboard.writeObjects(objects)
        suppression = RestoreSuppression(changeCount: pasteboard.changeCount, expiresAt: Date().addingTimeInterval(5))
        guard success else { throw Failure.writeFailed }
    }

    private enum ReadResult {
        case ignored, pending, ready(CaptureInput)
    }

    private func readEvent(expectedChangeCount: Int, compactMode: Bool,
                           allowIncompleteData: Bool) throws -> ReadResult {
        let items = pasteboard.pasteboardItems ?? []
        guard !items.isEmpty else { return .pending }
        let typeLists = items.map { $0.types.map(\.rawValue) }
        // Presence-only privacy assessment of every item precedes ALL payload reads.
        guard PasteboardProtocol.disposition(forTypes: typeLists) == .record else { return .ignored }
        guard items.count <= EventCodec.maxItems else { throw EventCodec.Failure.tooManyItems }
        for types in typeLists {
            guard types.count <= EventCodec.maxRepresentationsPerItem else { throw EventCodec.Failure.tooManyRepresentations }
            guard types.allSatisfy({ $0.utf8.count <= EventCodec.maxTypeBytes }) else { throw EventCodec.Failure.invalidType }
        }
        var values = typeLists.map { Array<ClipboardRepresentation?>(repeating: nil, count: $0.count) }
        // Read bounded fallback/provenance first, but keep the original flavor order.
        let preferred = Set([EventClassifier.textType, PasteboardProtocol.sourceType, PasteboardProtocol.remoteType])
        let supportedTypes = Set([EventClassifier.textType, "public.rtf", "public.png", "public.html", "public.file-url"])
        var missingSupportedBody = false
        var missingTextBody = false
        var hasSupportedBody = false
        var byteCount = 8 + items.count * 4
        for priority in [true, false] {
            for itemIndex in items.indices {
                for typeIndex in typeLists[itemIndex].indices {
                    let type = typeLists[itemIndex][typeIndex]
                    guard preferred.contains(type) == priority else { continue }
                    let bytes = items[itemIndex].data(forType: NSPasteboard.PasteboardType(type))
                        ?? (type == PasteboardProtocol.remoteType || type == PasteboardProtocol.sourceType ? Data() : nil)
                    guard let bytes else {
                        missingSupportedBody = missingSupportedBody || supportedTypes.contains(type)
                        missingTextBody = missingTextBody || type == EventClassifier.textType
                        continue
                    }
                    hasSupportedBody = hasSupportedBody || supportedTypes.contains(type)
                    byteCount += 12 + type.utf8.count + bytes.count
                    if byteCount > EventCodec.maxBlobBytes {
                        if priority { throw Failure.tooLarge }
                        // Stop fetching large private flavors; a complete bounded text
                        // fallback can still be retained under the saved capture limit.
                        guard pasteboard.changeCount == expectedChangeCount else { throw Failure.pasteboardChanged }
                        let partial = ClipboardEvent(items: values.map { ClipboardItem(dataList: $0.compactMap { $0 }) })
                        guard let text = partial.representation(for: EventClassifier.textType) else { throw Failure.tooLarge }
                        let markers = partial.items.flatMap(\.dataList).filter { $0.type == PasteboardProtocol.sourceType || $0.type == PasteboardProtocol.remoteType }
                        return .ready(CaptureInput(event: ClipboardEvent(items: [ClipboardItem(dataList: [text] + markers)]), fallbackOnly: true))
                    }
                    values[itemIndex][typeIndex] = ClipboardRepresentation(type: type, data: bytes)
                }
            }
        }
        guard pasteboard.changeCount == expectedChangeCount else { throw Failure.pasteboardChanged }
        // Do not delay a valid public fallback while optional rich/private flavors
        // are unavailable. Compact mode still needs its promised UTF-8 body.
        let needsBody = compactMode ? missingTextBody : missingSupportedBody && !hasSupportedBody
        if needsBody && !allowIncompleteData { return .pending }
        return .ready(CaptureInput(event: ClipboardEvent(items: values.map { ClipboardItem(dataList: $0.compactMap { $0 }) }), fallbackOnly: false))
    }
}

private struct CaptureInput: Sendable {
    let event: ClipboardEvent
    let fallbackOnly: Bool
}

private struct CaptureResult: Sendable {
    let prepared: PreparedEvent?
    let resourceRejected: Bool
}

/// Hashing, compact projection, summaries and binary encoding never run on the
/// AppKit actor. This serial actor also bounds concurrent processing work.
private actor CaptureProcessor {
    func prepare(_ input: CaptureInput, compactMode: Bool, maxEventBytes: Int64) -> CaptureResult {
        let event = input.event
        if input.fallbackOnly {
            guard let text = event.representation(for: EventClassifier.textType),
                  let value = EventCodec.strictUTF8(text.data),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !value.contains("\u{fffc}") else { return CaptureResult(prepared: nil, resourceRejected: true) }
        }
        let prepared = EventClassifier.prepare(event: event, compactMode: compactMode, maxEventBytes: maxEventBytes)
        let rejected = prepared == nil && EventClassifier.prepareResourceEvent(event, maxEventBytes: maxEventBytes) == nil
        return CaptureResult(prepared: prepared, resourceRejected: rejected)
    }
}
