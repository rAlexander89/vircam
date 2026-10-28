import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var updater: Updater
    @EnvironmentObject private var loginItem: LoginItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PreviewView(renderer: controller.preview)
                .frame(width: 528, height: 297)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text("Mirrored like your self-view in Zoom and Meet. Others see you unmirrored.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Form {
                Toggle("Vircam On", isOn: $controller.isOn)
                Picker("Camera", selection: $controller.selectedCameraID) {
                    ForEach(controller.cameras) { camera in
                        Text(camera.name).tag(Optional(camera.id))
                    }
                }
                LabeledContent("Status") {
                    HStack {
                        Text(controller.cameraStatus)
                        if controller.needsCameraAccess {
                            Button("Allow Camera Access…") { controller.allowCameraAccess() }
                        }
                    }
                }
                LabeledContent("Protection", value: controller.protectionStatus)
                LabeledContent("Faces", value: controller.facesStatus)
                LabeledContent("Performance", value: controller.performanceStatus)
                Toggle("Open at Login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.set($0) }))
                if let error = loginItem.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Show detection boxes (also visible in calls)", isOn: $controller.debugOverlay)
                LabeledContent("Vircam Camera") {
                    HStack {
                        Text(controller.virtualCameraConnected ? "Sending video" : "Not installed or not running")
                        if !controller.virtualCameraConnected {
                            Button("Install…") { controller.installCamera() }
                        }
                    }
                }
                if let status = updater.status {
                    LabeledContent("Update", value: status)
                } else if let release = updater.available {
                    LabeledContent("Update") {
                        HStack {
                            Text("Vircam \(release.version) is available (you have \(updater.currentVersion)).")
                            Button("Update") { updater.install() }
                        }
                    }
                }
                if let installStatus = controller.installStatus {
                    Text(installStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(width: 560)
        .fixedSize()
    }
}
