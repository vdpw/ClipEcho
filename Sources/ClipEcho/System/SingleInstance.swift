import AppKit
import CryptoKit
import Darwin

/// One native owner per database. Locks are kernel-owned and disappear on exit.
@MainActor
final class SingleInstance: NSObject {
  private var descriptor: Int32 = -1
  private let notification: Notification.Name
  var onActivate: (() -> Void)?

  init(qaNamespace: String? = nil) {
    // One native process per account, including after a database relocation.
    if let qaNamespace {
      let digest = SHA256.hash(data: Data(qaNamespace.utf8)).map { String(format: "%02x", $0) }
        .joined()
      notification = Notification.Name(
        "com.copy-stack.desktop.native.activate.\(getuid()).qa.\(digest.prefix(12))")
    } else {
      notification = Notification.Name("com.copy-stack.desktop.native.activate.\(getuid())")
    }
    super.init()
  }

  func acquire() throws -> Bool {
    let lockURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "clipecho-native-\(getuid())-\(notification.rawValue.split(separator: ".").last!).lock")
    descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw NativeError.instanceUnavailable }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
      (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1
    else {
      close(descriptor)
      descriptor = -1
      throw NativeError.instanceUnavailable
    }
    if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      let busy = errno == EWOULDBLOCK
      close(descriptor)
      descriptor = -1
      guard busy else { throw NativeError.instanceUnavailable }
      DistributedNotificationCenter.default().postNotificationName(
        notification, object: nil, userInfo: nil, deliverImmediately: true)
      return false
    }
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(activate), name: notification, object: nil)
    return true
  }

  @objc private func activate() { onActivate?() }

  func release() {
    DistributedNotificationCenter.default().removeObserver(self)
    if descriptor >= 0 {
      flock(descriptor, LOCK_UN)
      close(descriptor)
      descriptor = -1
    }
  }
}

enum NativeError: Error {
  case instanceUnavailable, loginUnavailable, invalidArguments, databaseUnavailable
}
