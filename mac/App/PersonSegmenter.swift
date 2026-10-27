import CoreVideo
import Vision

/// Per-person masks from Apple Vision, passed to the core so the user stays sharp along
/// their actual outline. Not thread-safe: call from one queue.
final class PersonSegmenter {
    private let request = VNGeneratePersonInstanceMaskRequest()

    /// One soft mask (32-bit float, 1 = person) per person in the frame. Empty if there
    /// are none or Vision fails; the core then falls back to a shape around the face.
    func masks(for pixelBuffer: CVPixelBuffer) -> [CVPixelBuffer] {
        do {
            try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up).perform([request])
            guard let observation = request.results?.first else { return [] }
            return try observation.allInstances.map { try observation.generateMask(forInstances: IndexSet(integer: $0)) }
        } catch {
            return []
        }
    }
}
