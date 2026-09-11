import ServiceManagement

/// Registers Clix as a login item.
///
/// `SMAppService` needs a valid code signature. An ad-hoc signed build of
/// Clix qualifies, but a build the user has moved or modified may not, so
/// failures are logged and reported as "off" rather than thrown.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns the error when the change could not be made, so the UI can say
    /// so instead of silently snapping the switch back.
    static func setEnabled(_ enabled: Bool) -> Error? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            log.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
            return error
        }
    }
}
