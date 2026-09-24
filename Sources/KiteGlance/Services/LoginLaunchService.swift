import Foundation
import ServiceManagement
import os.log

/// Wraps `SMAppService.mainApp` for "Open at Login".
///
/// `SMAppService` is the supported replacement for the deprecated
/// `SMLoginItemSetEnabled` and only resolves correctly on macOS 13+. On
/// earlier systems the toggle is a no-op and `isAvailable` reports false so
/// the Settings row can be hidden. Apple specifically recommends checking
/// `SMAppService.mainApp.status` before showing the toggle -- a macOS
/// 12 user would otherwise see a checkmark they cannot clear.
enum LoginLaunchService {
    private static let logger = Logger(subsystem: "com.kiteglance", category: "LoginLaunch")

    /// `false` on macOS 12 and earlier, where `SMAppService.mainApp` is
    /// unavailable. The Settings UI hides the toggle when this is `false`.
    static var isAvailable: Bool {
        if #available(macOS 13.0, *) {
            return true
        }
        return false
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    /// Sets the launch-at-login state. Returns the new effective state -- a
    /// registration request can be denied by the system, in which case the
    /// caller should resync its UI from the returned value rather than the
    /// one it asked for.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            do {
                if enabled {
                    if service.status != .enabled {
                        try service.register()
                    }
                } else {
                    if service.status == .enabled {
                        try service.unregister()
                    }
                }
            } catch {
                // The user may have denied the registration prompt or the
                // profile may be managed. Either way the UI needs to read
                // back the actual state, not the requested one.
                logger.error("Failed to set launch-at-login: \(error.localizedDescription, privacy: .public)")
                Task {
                    await Log.shared.structured(
                        .error,
                        "Failed to set launch-at-login: {Error}",
                        properties: ["Error": error.localizedDescription]
                    )
                }
            }
            return service.status == .enabled
        }
        return false
    }
}
