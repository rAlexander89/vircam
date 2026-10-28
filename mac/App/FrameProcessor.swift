import CoreMedia
import CoreVideo
import VideoToolbox

/// Runs frames through the C++ core. Not thread-safe: call from one queue.
final class FrameProcessor {
    struct EngineError: LocalizedError {
        let errorDescription: String?
    }

    private let engine: OpaquePointer
    private let outputPool: CVPixelBufferPool

    var debugOverlay = false {
        didSet { vircam_engine_set_debug_overlay(engine, debugOverlay ? 1 : 0) }
    }

    /// `modelDirectory` must contain the core's model files.
    init(modelDirectory: String) throws {
        var message = [CChar](repeating: 0, count: 512)
        guard let engine = vircam_engine_create(modelDirectory, &message, Int32(message.count)) else {
            throw EngineError(errorDescription: "Could not start the processing engine: \(String(cString: message))")
        }
        self.engine = engine
        guard let pool = makeVirtualCameraPool() else {
            vircam_engine_destroy(engine)
            throw EngineError(errorDescription: "Could not allocate video buffers.")
        }
        outputPool = pool
    }

    deinit {
        vircam_engine_destroy(engine)
    }

    /// Processes a frame at the virtual camera's size into a new buffer. Returns nil if the
    /// frame could not be processed; such frames must be dropped, never shown raw.
    func process(_ input: CVPixelBuffer, timestamp: CMTime, masks: [CVPixelBuffer]) -> (CVPixelBuffer, vircam_frame_info)? {
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPool, &output)
        guard let output, let info = process(input, into: output, timestamp: timestamp.seconds, masks: masks) else {
            return nil
        }
        return (output, info)
    }

    /// Processes `input` into `output`; both BGRA and the same size. `masks` are person
    /// masks from `PersonSegmenter` for this same frame.
    func process(_ input: CVPixelBuffer, into output: CVPixelBuffer, timestamp: Double,
                 masks: [CVPixelBuffer]) -> vircam_frame_info? {
        CVPixelBufferLockBaseAddress(input, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])
        masks.forEach { CVPixelBufferLockBaseAddress($0, .readOnly) }
        defer {
            masks.forEach { CVPixelBufferUnlockBaseAddress($0, .readOnly) }
            CVPixelBufferUnlockBaseAddress(output, [])
            CVPixelBufferUnlockBaseAddress(input, .readOnly)
        }

        var inImage = image(of: input)
        var outImage = image(of: output)
        let personMasks = masks.compactMap { mask -> vircam_person_mask? in
            guard CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent32Float,
                  let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
            return vircam_person_mask(data: base.assumingMemoryBound(to: Float.self),
                                      width: Int32(CVPixelBufferGetWidth(mask)),
                                      height: Int32(CVPixelBufferGetHeight(mask)),
                                      stride: Int32(CVPixelBufferGetBytesPerRow(mask)))
        }
        var info = vircam_frame_info()
        let status = personMasks.withUnsafeBufferPointer { masksPointer in
            vircam_engine_process_with_masks(engine, &inImage, &outImage, timestamp,
                                             masksPointer.baseAddress, Int32(masksPointer.count), &info)
        }
        return status == VIRCAM_OK ? info : nil
    }

    private func image(of pixelBuffer: CVPixelBuffer) -> vircam_image {
        vircam_image(data: CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self),
                     width: Int32(CVPixelBufferGetWidth(pixelBuffer)),
                     height: Int32(CVPixelBufferGetHeight(pixelBuffer)),
                     stride: Int32(CVPixelBufferGetBytesPerRow(pixelBuffer)))
    }
}

/// Brings camera frames to the virtual camera's size and format. Capture is configured
/// for that already, but some cameras ignore it. Not thread-safe: call from one queue.
final class FrameNormalizer {
    private let pool: CVPixelBufferPool?
    private var scaler: VTPixelTransferSession?

    init() {
        pool = makeVirtualCameraPool()
    }

    func normalize(_ input: CVPixelBuffer) -> CVPixelBuffer? {
        if CVPixelBufferGetWidth(input) == Int(VirtualCamera.width),
           CVPixelBufferGetHeight(input) == Int(VirtualCamera.height),
           CVPixelBufferGetPixelFormatType(input) == VirtualCamera.pixelFormat {
            return input
        }
        if scaler == nil {
            VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &scaler)
            if let scaler {
                VTSessionSetProperty(scaler, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
            }
        }
        var scaled: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &scaled)
        }
        guard let scaler, let scaled, VTPixelTransferSessionTransferImage(scaler, from: input, to: scaled) == noErr else {
            return nil
        }
        return scaled
    }
}

private func makeVirtualCameraPool() -> CVPixelBufferPool? {
    let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: VirtualCamera.pixelFormat,
        kCVPixelBufferWidthKey as String: VirtualCamera.width,
        kCVPixelBufferHeightKey as String: VirtualCamera.height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    var pool: CVPixelBufferPool?
    CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
    return pool
}
