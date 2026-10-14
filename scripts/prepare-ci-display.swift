import AppKit
import CoreGraphics
import Foundation

// CI exercises real 600x700 and 1000x900 windows. Some virtual runners start
// with a smaller desktop, so AppKit constrains their frames before assertions.
// This helper changes only an ephemeral CI VM's login-session configuration.
let minimumVisibleWidth: CGFloat = 1000
let minimumVisibleHeight: CGFloat = 900

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("CI display preparation failed: \(message)\n".utf8))
  exit(1)
}

@MainActor
func mainScreen() -> NSScreen? {
  let display = CGMainDisplayID()
  return NSScreen.screens.first {
    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
      == display
  }
}

@MainActor
func logScreens(_ context: String) {
  for screen in NSScreen.screens {
    let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "unknown"
    print("\(context): display=\(display) frame=\(NSStringFromRect(screen.frame)) "
      + "visibleFrame=\(NSStringFromRect(screen.visibleFrame)) scale=\(screen.backingScaleFactor)")
  }
}

@MainActor
func hasEnoughSpace() -> Bool {
  guard let screen = mainScreen() else { return false }
  return screen.visibleFrame.width >= minimumVisibleWidth
    && screen.visibleFrame.height >= minimumVisibleHeight
}

@MainActor
func waitForEnoughSpace() -> Bool {
  let deadline = Date().addingTimeInterval(5)
  repeat {
    // AppKit must receive the screen-parameter notification after a VM tool
    // changes resolution; checking its cached NSScreen immediately can be stale.
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    if hasEnoughSpace() { return true }
  } while Date() < deadline
  return false
}

@MainActor
func prepareDisplay() {
  guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else {
    fail("this helper may run only on macOS GitHub Actions runners")
  }
  _ = NSApplication.shared
  NSApp.setActivationPolicy(.prohibited)
  let display = CGMainDisplayID()
  guard display != 0, let screen = mainScreen() else {
    fail("the runner has no main display or AppKit screen")
  }
  logScreens("Initial CI screen")
  let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
  let modes = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
  for mode in modes {
    print("CG mode id=\(mode.ioDisplayModeID): \(mode.width)x\(mode.height) "
      + "pixels=\(mode.pixelWidth)x\(mode.pixelHeight) hz=\(mode.refreshRate) "
      + "desktopUsable=\(mode.isUsableForDesktopGUI())")
  }
  if hasEnoughSpace() {
    print("The CI display already has enough space for every window-size assertion.")
    return
  }

  // Account for the menu bar and Dock using logical dimensions. A Retina
  // mode's pixel dimensions alone do not establish usable AppKit space.
  let reservedWidth = max(0, screen.frame.width - screen.visibleFrame.width)
  let reservedHeight = max(0, screen.frame.height - screen.visibleFrame.height)
  let requiredWidth = max(1280, Int(ceil(minimumVisibleWidth + reservedWidth)))
  let requiredHeight = max(1024, Int(ceil(minimumVisibleHeight + reservedHeight)))
  let candidates = modes.filter {
    $0.isUsableForDesktopGUI() && $0.width >= requiredWidth && $0.height >= requiredHeight
  }.sorted {
    let firstArea = $0.width * $0.height
    let secondArea = $1.width * $1.height
    if firstArea != secondArea { return firstArea < secondArea }
    return $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight
  }

  for mode in candidates {
    print("Preparing CI display with public CoreGraphics mode \(mode.width)x\(mode.height).")
    var configuration: CGDisplayConfigRef?
    let begin = CGBeginDisplayConfiguration(&configuration)
    guard begin == .success else {
      print("CGBeginDisplayConfiguration failed: \(begin.rawValue)")
      break
    }
    let configure = CGConfigureDisplayWithDisplayMode(configuration, display, mode, nil)
    if configure != .success {
      CGCancelDisplayConfiguration(configuration)
      print("CGConfigureDisplayWithDisplayMode failed: \(configure.rawValue)")
      continue
    }
    // CGDisplaySetDisplayMode would revert when this helper exits. forSession
    // preserves the mode for the following app process without a permanent save.
    let complete = CGCompleteDisplayConfiguration(configuration, .forSession)
    if complete != .success {
      print("CGCompleteDisplayConfiguration failed: \(complete.rawValue)")
      continue
    }
    let ready = waitForEnoughSpace()
    logScreens("After CoreGraphics preparation")
    if ready { return }
  }

  // Anka can expose a new mode when none of the currently advertised modes
  // provides enough room. Use the VM's existing utility without brew installs.
  let ankaTool = "/Library/Application Support/Veertu/Anka/addons/change_res"
  if FileManager.default.isExecutableFile(atPath: ankaTool) {
    print("Preparing CI display with the installed Anka tool: 1920x1200x32@30")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ankaTool)
    process.arguments = ["1920x1200x32@30"]
    do {
      try process.run()
      process.waitUntilExit()
      print("Anka display tool exit status: \(process.terminationStatus)")
      let ready = waitForEnoughSpace()
      logScreens("After Anka preparation")
      if process.terminationStatus == 0 && ready { return }
    } catch {
      print("The Anka display tool could not run: \(error)")
    }
  } else {
    print("The runner has no installed Anka change_res utility.")
  }
  fail("no available mode or VM utility provided a main visibleFrame of at least "
    + "\(Int(minimumVisibleWidth))x\(Int(minimumVisibleHeight)); window assertions remain enabled")
}

prepareDisplay()
