import AVFoundation

struct CameraInfo: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Reads frames from a real camera as BGRA at the virtual camera's resolution.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Called on the capture queue for every frame.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "dev.viracm.capture", qos: .userInteractive)
    private var currentInput: AVCaptureDeviceInput?

    override init() {
        super.init()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: VirtualCamera.pixelFormat,
            kCVPixelBufferWidthKey as String: VirtualCamera.width,
            kCVPixelBufferHeightKey as String: VirtualCamera.height,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        session.commitConfiguration()
    }

    /// Real cameras only. Virtual cameras (including Viracm's own) are excluded so the
    /// app can never read its own output or another unprotected virtual feed.
    static func availableCameras() -> [CameraInfo] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video,
                                         position: .unspecified)
            .devices
            .filter { UInt32(bitPattern: $0.transportType) != VirtualCamera.virtualTransportType }
            .filter { $0.uniqueID != VirtualCamera.deviceID.uuidString && $0.localizedName != VirtualCamera.deviceName }
            .map { CameraInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func start(cameraID: String) throws {
        guard let device = AVCaptureDevice(uniqueID: cameraID) else {
            throw CaptureError.cameraNotFound
        }
        let input = try AVCaptureDeviceInput(device: device)
        queue.sync {
            session.beginConfiguration()
            if let currentInput {
                session.removeInput(currentInput)
            }
            if session.canAddInput(input) {
                session.addInput(input)
                currentInput = input
            }
            session.commitConfiguration()
            if !session.isRunning {
                session.startRunning()
            }
        }
        if currentInput !== input {
            throw CaptureError.cannotUseCamera
        }
    }

    func stop() {
        queue.sync {
            session.stopRunning()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    enum CaptureError: LocalizedError {
        case cameraNotFound
        case cannotUseCamera

        var errorDescription: String? {
            switch self {
            case .cameraNotFound: "The selected camera is no longer connected."
            case .cannotUseCamera: "The selected camera could not be opened."
            }
        }
    }
}
