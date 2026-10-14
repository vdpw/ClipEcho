import AppKit
import ClipEchoCore

struct LaunchOptions {
  var database: URL?
  var readOnly = false
  var hidden = false
  var verify = false
  var selfTest = false
  var qa = false
  var mirrorURL: URL?
  var mirrorMaxBytes = 4096

  init(arguments: [String]) throws {
    // Only QA bundles embed this private fixture path in LSEnvironment. It
    // keeps Finder/CUA relaunches isolated even when no CLI arguments survive.
    if let fixture = ProcessInfo.processInfo.environment["CLIPECHO_NATIVE_QA_DATABASE"] {
      guard fixture.hasPrefix("/"), !fixture.isEmpty else { throw NativeError.invalidArguments }
      database = URL(fileURLWithPath: fixture)
      qa = true
    }
    var index = 0
    while index < arguments.count {
      switch arguments[index] {
      case "--database":
        index += 1
        guard index < arguments.count, arguments[index].hasPrefix("/") else {
          throw NativeError.invalidArguments
        }
        database = URL(fileURLWithPath: arguments[index])
      case "--read-only": readOnly = true
      case "--hidden", "--copy-stack-autostart": hidden = true
      case "--verify-database":
        verify = true
        readOnly = true
      case "--self-test": selfTest = true
      case "--qa": qa = true
      case "--copy-stack-history-jsonl":
        index += 1
        guard index < arguments.count, arguments[index].hasPrefix("/") else {
          throw NativeError.invalidArguments
        }
        mirrorURL = URL(fileURLWithPath: arguments[index])
      case "--copy-stack-history-jsonl-max-data-bytes":
        index += 1
        guard index < arguments.count, let bytes = Int(arguments[index]), bytes >= 0,
          bytes <= EventCodec.maxBlobBytes
        else { throw NativeError.invalidArguments }
        mirrorMaxBytes = bytes
      case let value where value.hasPrefix("--copy-stack-history-jsonl="):
        let path = String(value.dropFirst("--copy-stack-history-jsonl=".count))
        guard path.hasPrefix("/") else { throw NativeError.invalidArguments }
        mirrorURL = URL(fileURLWithPath: path)
      case let value where value.hasPrefix("--copy-stack-history-jsonl-max-data-bytes="):
        guard let bytes = Int(value.dropFirst("--copy-stack-history-jsonl-max-data-bytes=".count)),
          bytes >= 0, bytes <= EventCodec.maxBlobBytes
        else { throw NativeError.invalidArguments }
        mirrorMaxBytes = bytes
      case let value where value.hasPrefix("-psn_"): break
      default: throw NativeError.invalidArguments
      }
      index += 1
    }
    if qa && database == nil { throw NativeError.invalidArguments }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let options: LaunchOptions
  private var controller: AppController?
  private var instance: SingleInstance?
  private var waitingForTermination = false
  private var qaPasteboard: NSPasteboard?
  init(options: LaunchOptions) { self.options = options }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let loginEvent =
      NSAppleEventManager.shared().currentAppleEvent?
      .paramDescriptor(forKeyword: 0x7072_6474)?.enumCodeValue == 0x6c67_6974
    Task { @MainActor in
      do {
        let locator = StorageLocator()
        let url = try options.database ?? locator.databaseURL()
        let instance = SingleInstance(qaNamespace: options.qa ? url.path : nil)
        self.instance = instance
        guard try instance.acquire() else {
          NSApp.terminate(nil)
          return
        }
        let readOnly = options.readOnly
        let historyLocator =
          options.database == nil ? locator : StorageLocator(root: url.deletingLastPathComponent())
        let history = try await Task.detached(priority: .userInitiated) {
          HistoryService(
            storage: try SQLiteStore(url: url, readOnly: readOnly, locator: historyLocator))
        }.value
        var mirror: HistoryMirror?
        if let output = options.mirrorURL {
          let configuration = HistoryMirrorConfiguration(
            outputURL: output, maxDataBytes: options.mirrorMaxBytes)
          mirror = try await Task.detached {
            try HistoryMirror(configuration: configuration, databaseURL: url)
          }.value
          try await mirror?.scheduleRefresh()
        }
        if options.qa { qaPasteboard = NSPasteboard.withUniqueName() }
        let controller = AppController(
          history: history, snapshot: try await history.snapshot(), readOnly: options.readOnly,
          mirror: mirror,
          pasteboard: qaPasteboard ?? .general, autosaveWindowFrame: !options.qa,
          qaMode: options.qa)
        self.controller = controller
        instance.onActivate = { [weak controller] in controller?.activateWindow() }
        controller.start(hidden: options.hidden || loginEvent)
      } catch {
        NSApp.setActivationPolicy(.regular)
        let alert = NSAlert()
        alert.messageText = "ClipEcho"
        alert.informativeText = L10n.string("storageError", language: "system")
        alert.addButton(withTitle: L10n.string("ok", language: "system"))
        alert.runModal()
        NSApp.terminate(nil)
      }
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    controller?.activateWindow()
    return true
  }
  func applicationWillTerminate(_ notification: Notification) {
    controller?.stop()
    instance?.release()
    qaPasteboard?.releaseGlobally()
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let controller, controller.mirror != nil else { return .terminateNow }
    guard !waitingForTermination else { return .terminateLater }
    waitingForTermination = true
    controller.stop()
    Task { @MainActor in
      await controller.flushMirrorForTermination()
      completeTermination()
    }
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(2))
      completeTermination()
    }
    return .terminateLater
  }
  private func completeTermination() {
    guard waitingForTermination else { return }
    waitingForTermination = false
    NSApp.reply(toApplicationShouldTerminate: true)
  }
}

@main
struct ClipEchoApp {
  @MainActor static func main() async {
    do {
      let options = try LaunchOptions(arguments: Array(CommandLine.arguments.dropFirst()))
      if options.verify {
        try verifyDatabase(options.database ?? StorageLocator().databaseURL())
        return
      }
      if options.selfTest {
        try await NativeSelfTest.run()
        return
      }
      let app = NSApplication.shared
      let delegate = AppDelegate(options: options)
      app.delegate = delegate
      app.setActivationPolicy(.accessory)
      withExtendedLifetime(delegate) { app.run() }
    } catch {
      // CLI failures are intentionally body- and path-free.
      if let failure = error as? NativeSelfTest.Failure {
        print("Native self-test assertion: \(failure)")
      }
      if let failure = error as? ClipboardCaptureSelfTest.Failure {
        print("Clipboard capture self-test assertion: \(failure)")
      }
      if CommandLine.arguments.contains("--self-test") {
        if let failure = error as? StorageError {
          print("Native self-test storage failure: \(failure)")
        } else {
          print("Native self-test failure category: \(type(of: error))")
        }
      }
      FileHandle.standardError.write(
        Data(
          "ClipEcho failed. Check the database format, private file permissions, and launch arguments.\n"
            .utf8))
      exit(1)
    }
  }

  /// Inspects live legacy history without updating settings, permissions, or SQLite rows.
  private static func verifyDatabase(_ url: URL) throws {
    let store = try SQLiteStore(url: url, readOnly: true)
    var cursor: HistoryCursor?
    var count = 0
    var binaryRoundTrips = 0
    var legacyRoundTrips = 0
    var identities = 0
    repeat {
      let page = try store.page(cursor: cursor, limit: 100)
      for item in page.items {
        guard let stored = try store.event(contentHash: item.contentHash) else {
          throw StorageError.invalidEvent
        }
        let event = try EventCodec.decode(stored.eventData)
        let encoded = try EventCodec.encode(event)
        guard try EventCodec.decode(encoded) == event else { throw StorageError.invalidEvent }
        if stored.eventData.starts(with: Data("CSB1".utf8)) {
          guard encoded == stored.eventData else { throw StorageError.invalidEvent }
          binaryRoundTrips += 1
        } else {
          legacyRoundTrips += 1
        }
        if EventClassifier.contentHash(event: event, compactMode: false) == item.contentHash {
          identities += 1
        }
        count += 1
      }
      cursor = page.nextCursor
    } while cursor != nil
    guard binaryRoundTrips + legacyRoundTrips == count, identities == count else {
      throw StorageError.invalidEvent
    }
    print(
      "Database compatible: \(count) visible rows, \(binaryRoundTrips) exact CSB1 round trips, \(legacyRoundTrips) equivalent legacy JSON round trips, \(identities) matching content identities. Read-only inspection."
    )
  }
}
