import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--process-image") {
            exit(ImageTool.run(CommandLine.arguments))
        }
        VircamApp.main()
    }
}

struct VircamApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject private var controller = AppController()

    var body: some Scene {
        Window("Vircam", id: "main") {
            ContentView()
                .environmentObject(controller)
                .environmentObject(controller.updater)
                .environmentObject(controller.loginItem)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarMenu()
                .environmentObject(controller)
                .environmentObject(controller.updater)
                .environmentObject(controller.loginItem)
        } label: {
            Image(controller.isOn ? "TrayOn" : "TrayOff")
        }
    }
}

/// Vircam lives in the menu bar: the dashboard opens only from "Open Dashboard", and
/// closing it keeps Vircam running.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI opens the dashboard at launch; macOS 14 has no way to suppress that.
        DispatchQueue.main.async {
            NSApp.windows.filter { $0.title == "Vircam" }.forEach { $0.close() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

private struct MenuBarMenu: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var updater: Updater
    @EnvironmentObject private var loginItem: LoginItem
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusText)
        if controller.needsCameraAccess {
            Button("Allow Camera Access…") { controller.allowCameraAccess() }
        }
        Toggle("Vircam On", isOn: $controller.isOn)
            .keyboardShortcut("o")
        if !controller.cameras.isEmpty {
            Picker(cameraLabel, selection: $controller.selectedCameraID) {
                ForEach(controller.cameras) { camera in
                    Text(camera.name).tag(Optional(camera.id))
                }
            }
        }
        Divider()
        if let status = updater.status {
            Text(status)
        } else if let release = updater.available {
            Button("Update to Vircam \(release.version)") { updater.install() }
        } else {
            Button("Check for Updates") { Task { await updater.check() } }
        }
        Toggle("Open at Login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.set($0) }))
        Button("Open Dashboard") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit Vircam") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var cameraLabel: String {
        let name = controller.cameras.first { $0.id == controller.selectedCameraID }?.name
        return name.map { "Camera: \($0)" } ?? "Camera"
    }

    private var statusText: String {
        guard controller.isOn else { return "Off: calling apps see a placeholder" }
        if controller.cameraStatus != "Running" { return controller.cameraStatus }
        return controller.virtualCameraConnected ? "On: sending video" : "On: Vircam Camera not installed"
    }
}
