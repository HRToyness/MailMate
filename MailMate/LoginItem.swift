import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` so Settings can toggle
/// "Launch at login" without handling the status-code noise directly.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns true if the registration change succeeded.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.write("LoginItem.setEnabled(\(enabled)) ok, status=\(SMAppService.mainApp.status.rawValue)")
            return true
        } catch {
            Log.write("LoginItem.setEnabled(\(enabled)) failed: \(error.localizedDescription)")
            return false
        }
    }
}
