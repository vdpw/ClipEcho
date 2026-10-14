import Foundation
import ServiceManagement

@MainActor
protocol LoginItemManaging {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

/// The operating system owns login state; it is not duplicated in SQLite settings.
@MainActor
final class LoginItemService: LoginItemManaging {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    func setEnabled(_ enabled: Bool) throws {
        guard Bundle.main.bundleURL.pathExtension == "app" else { throw NativeError.loginUnavailable }
        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled { try service.register() }
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems(); return }
            guard service.status == .enabled else { throw NativeError.loginUnavailable }
        } else {
            if service.status != .notRegistered { try service.unregister() }
            guard service.status == .notRegistered else { throw NativeError.loginUnavailable }
        }
    }
}
