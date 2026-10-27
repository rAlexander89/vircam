import AVFoundation
import Combine
import Foundation

/// Owns the capture → process → output pipeline and exposes its state to the UI.
@MainActor
final class AppController: ObservableObject {
    @Published private(set) var cameras: [CameraInfo] = []
    @Published var selectedCameraID: String? {
        didSet { if selectedCameraID != oldValue { startSelectedCamera() } }
    }
    @Published var debugOverlay = false {
        didSet { pipeline?.setDebugOverlay(debugOverlay) }
    }
    @Published private(set) var cameraStatus = "Starting…"
    @Published private(set) var protectionStatus = "—"
    @Published private(set) var facesStatus = "—"
    @Published private(set) var performanceStatus = "—"
    @Published private(set) var virtualCameraConnected = false
    @Published private(set) var installStatus: String?

    let preview = PreviewRenderer()

    private let capture = CameraCapture()
    private let pipeline: Pipeline?
    private let pipelineError: String?
    private let installer = ExtensionInstaller()
    private var statusTimer: Timer?

    init() {
        do {
            let pipeline = try Pipeline(modelDirectory: Bundle.main.resourcePath ?? "", preview: preview)
            capture.onFrame = { pixelBuffer, timestamp in pipeline.handle(pixelBuffer, timestamp: timestamp) }
            self.pipeline = pipeline
            pipelineError = nil
        } catch {
            pipeline = nil
            pipelineError = error.localizedDescription
        }
        installer.onStatus = { [weak self] message in self?.installStatus = message }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
        Task { await start() }
    }

    func installCamera() {
        installer.activate()
    }

    func refreshCameras() {
        cameras = CameraCapture.availableCameras()
        if selectedCameraID == nil || !cameras.contains(where: { $0.id == selectedCameraID }) {
            selectedCameraID = cameras.first?.id
        }
    }

    private func start() async {
        if let pipelineError {
            cameraStatus = pipelineError
            return
        }
        guard await CameraCapture.requestAccess() else {
            cameraStatus = "Camera access denied. Allow Viracm in System Settings › Privacy & Security › Camera."
            return
        }
        refreshCameras()
        if cameras.isEmpty {
            cameraStatus = "No camera found."
        }
    }

    private func startSelectedCamera() {
        guard let selectedCameraID else { return }
        do {
            try capture.start(cameraID: selectedCameraID)
            cameraStatus = "Running"
        } catch {
            cameraStatus = error.localizedDescription
        }
    }

    private func refreshStatus() {
        guard let stats = pipeline?.takeStats() else { return }
        virtualCameraConnected = stats.virtualCameraConnected
        if stats.frames == 0 {
            protectionStatus = "No frames"
            facesStatus = "—"
            performanceStatus = "—"
            return
        }
        let protectedFrames = stats.frames - stats.fullBlurFrames
        if protectedFrames == 0 {
            protectionStatus = "Fully blurred (no single person confirmed as you)"
        } else if stats.outlineFrames == protectedFrames {
            protectionStatus = stats.fullBlurFrames == 0 ? "You are sharp along your outline" : "Partly fully blurred"
        } else {
            protectionStatus = "Outline not found; using a shape around your face"
        }
        facesStatus = "\(stats.lastFacesDetected) detected, \(stats.lastFacesBlurred) blurred"
        performanceStatus = String(format: "%.0f fps · outline %.1f ms · faces + blur %.1f ms",
                                   stats.framesPerSecond, stats.averageSegmentMilliseconds, stats.averageMilliseconds)
    }
}

/// Two stages, each on its own queue so they overlap across frames: Vision segments
/// frame N while the core processes frame N-1. A frame arriving while its stage is busy
/// is dropped. `takeStats` and `setDebugOverlay` may be called from any thread.
private final class Pipeline: @unchecked Sendable {
    struct Stats {
        var frames = 0
        var fullBlurFrames = 0
        var outlineFrames = 0
        var totalMilliseconds = 0.0
        var segmentMilliseconds = 0.0
        var lastFacesDetected = 0
        var lastFacesBlurred = 0
        var framesPerSecond = 0.0
        var averageMilliseconds = 0.0
        var averageSegmentMilliseconds = 0.0
        var virtualCameraConnected = false
    }

    private let normalizer = FrameNormalizer()
    private let segmenter = PersonSegmenter()
    private let processor: FrameProcessor
    private let output = VirtualCameraOutput()
    private let preview: PreviewRenderer
    private var lastConnectAttempt = Date.distantPast

    private let segmentQueue = DispatchQueue(label: "dev.viracm.segment", qos: .userInteractive)
    private let processQueue = DispatchQueue(label: "dev.viracm.process", qos: .userInteractive)

    private let lock = NSLock()
    private var segmentBusy = false
    private var processBusy = false
    private var stats = Stats()
    private var statsWindowStart = Date()
    private var requestedDebugOverlay = false

    init(modelDirectory: String, preview: PreviewRenderer) throws {
        processor = try FrameProcessor(modelDirectory: modelDirectory)
        self.preview = preview
        // Vision loads its model on first use, which takes seconds; do it before frames arrive.
        segmentQueue.async { [segmenter] in
            var blank: CVPixelBuffer?
            CVPixelBufferCreate(nil, Int(VirtualCamera.width), Int(VirtualCamera.height), VirtualCamera.pixelFormat, nil, &blank)
            if let blank { _ = segmenter.masks(for: blank) }
        }
    }

    func setDebugOverlay(_ enabled: Bool) {
        lock.lock()
        requestedDebugOverlay = enabled
        lock.unlock()
    }

    /// Called on the capture queue.
    func handle(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard claim(\.segmentBusy) else { return }
        segmentQueue.async { [self] in
            let frame = normalizer.normalize(pixelBuffer)
            let start = Date()
            let masks = frame.map { segmenter.masks(for: $0) } ?? []
            let segmentMilliseconds = Date().timeIntervalSince(start) * 1000
            release(\.segmentBusy)
            guard let frame, claim(\.processBusy) else { return }
            processQueue.async { [self] in
                process(frame, timestamp: timestamp, masks: masks, segmentMilliseconds: segmentMilliseconds)
                release(\.processBusy)
            }
        }
    }

    private func process(_ frame: CVPixelBuffer, timestamp: CMTime, masks: [CVPixelBuffer], segmentMilliseconds: Double) {
        lock.lock()
        let debugOverlay = requestedDebugOverlay
        lock.unlock()
        if processor.debugOverlay != debugOverlay {
            processor.debugOverlay = debugOverlay
        }

        if !output.isConnected, Date().timeIntervalSince(lastConnectAttempt) > 2 {
            lastConnectAttempt = Date()
            output.connect()
        }

        // A nil result means the frame is dropped; raw frames are never shown or sent.
        guard let (processed, info) = processor.process(frame, timestamp: timestamp, masks: masks) else { return }
        output.send(processed)
        preview.display(processed)

        lock.lock()
        stats.frames += 1
        stats.totalMilliseconds += info.process_ms
        stats.segmentMilliseconds += segmentMilliseconds
        if info.mode == VIRACM_FRAME_FULL_BLUR {
            stats.fullBlurFrames += 1
        } else if info.used_person_mask != 0 {
            stats.outlineFrames += 1
        }
        stats.lastFacesDetected = Int(info.faces_detected)
        stats.lastFacesBlurred = Int(info.faces_blurred)
        stats.virtualCameraConnected = output.isConnected
        lock.unlock()
    }

    private func claim(_ flag: ReferenceWritableKeyPath<Pipeline, Bool>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if self[keyPath: flag] { return false }
        self[keyPath: flag] = true
        return true
    }

    private func release(_ flag: ReferenceWritableKeyPath<Pipeline, Bool>) {
        lock.lock()
        self[keyPath: flag] = false
        lock.unlock()
    }

    func takeStats() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        var snapshot = stats
        let elapsed = Date().timeIntervalSince(statsWindowStart)
        if snapshot.frames > 0 {
            snapshot.framesPerSecond = Double(snapshot.frames) / elapsed
            snapshot.averageMilliseconds = snapshot.totalMilliseconds / Double(snapshot.frames)
            snapshot.averageSegmentMilliseconds = snapshot.segmentMilliseconds / Double(snapshot.frames)
        }
        stats = Stats(virtualCameraConnected: stats.virtualCameraConnected)
        statsWindowStart = Date()
        return snapshot
    }
}
