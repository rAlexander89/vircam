import Foundation
import SystemExtensions

/// Activates the Viracm Camera system extension embedded in the app bundle.
/// Requires a build signed with an Apple Developer team, run from /Applications.
final class ExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate {
    var onStatus: ((String) -> Void)?

    private var extensionIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "") + ".CameraExtension"
    }

    func activate() {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
            onStatus?("Move Viracm to /Applications before installing the camera.")
            return
        }
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        onStatus?("Installing camera…")
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        onStatus?("Approve Viracm in System Settings › General › Login Items & Extensions › Camera Extensions.")
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed: onStatus?("Camera installed.")
        case .willCompleteAfterReboot: onStatus?("Camera will be available after a restart.")
        @unknown default: onStatus?("Camera install finished.")
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        onStatus?("Camera install failed: \(error.localizedDescription)")
    }
}
