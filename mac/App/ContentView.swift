import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PreviewView(renderer: controller.preview)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(minWidth: 480)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text("Preview shows exactly what calling apps receive.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Form {
                Picker("Camera", selection: $controller.selectedCameraID) {
                    ForEach(controller.cameras) { camera in
                        Text(camera.name).tag(Optional(camera.id))
                    }
                }
                LabeledContent("Status", value: controller.cameraStatus)
                LabeledContent("Protection", value: controller.protectionStatus)
                LabeledContent("Faces", value: controller.facesStatus)
                LabeledContent("Performance", value: controller.performanceStatus)
                Toggle("Show detection boxes (also visible in calls)", isOn: $controller.debugOverlay)
                LabeledContent("Viracm Camera") {
                    HStack {
                        Text(controller.virtualCameraConnected ? "Sending video" : "Not installed or not running")
                        if !controller.virtualCameraConnected {
                            Button("Install…") { controller.installCamera() }
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
        .frame(minWidth: 560)
    }
}
