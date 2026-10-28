import Foundation
import ServiceManagement

/// Opens Vircam at login. Turned on the first time Vircam runs; the user can turn it off.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var error: String?

    private static let configuredKey = "loginItemConfigured"

    init() {
        if !UserDefaults.standard.bool(forKey: Self.configuredKey) {
            UserDefaults.standard.set(true, forKey: Self.configuredKey)
            set(true)
        }
        refresh()
    }

    func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = "Couldn't change Open at Login: \(error.localizedDescription)"
        }
        refresh()
    }

    private func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
