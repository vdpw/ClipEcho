import AppKit
import CoreFoundation

/// Deliver background results even while AppKit runs a nested menu loop.
enum MenuTrackingDelivery {
  static func post(_ update: @escaping @MainActor @Sendable () -> Void) {
    let mainLoop = CFRunLoopGetMain()
    let modes =
      [
        RunLoop.Mode.eventTracking.rawValue, RunLoop.Mode.modalPanel.rawValue,
        RunLoop.Mode.default.rawValue,
      ] as CFArray
    CFRunLoopPerformBlock(mainLoop, modes) {
      MainActor.assumeIsolated { update() }
    }
    CFRunLoopWakeUp(mainLoop)
  }
}
