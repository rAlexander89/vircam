import CoreImage
import Foundation

/// `Viracm.app/Contents/MacOS/Viracm --process-image <input> <output.png> [--debug]`
///
/// Runs the full Mac pipeline (Vision outlines + core) on a still image, for testing
/// without a camera. The image is fed as 15 frames at 30 fps, since a face must be seen
/// in several frames before it is kept sharp.
enum ImageTool {
    static func run(_ arguments: [String]) -> Int32 {
        let rest = Array(arguments.drop { $0 != "--process-image" }.dropFirst())
        let paths = rest.filter { !$0.hasPrefix("--") }
        guard paths.count == 2 else {
            print("usage: Viracm --process-image <input> <output.png> [--debug]")
            return 2
        }
        guard let image = CIImage(contentsOf: URL(fileURLWithPath: paths[0])) else {
            print("error: cannot read \(paths[0])")
            return 1
        }

        let scale = 1280 / image.extent.width
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = Int(scaled.extent.width.rounded()), height = Int(scaled.extent.height.rounded())
        guard let input = makeBuffer(width: width, height: height),
              let output = makeBuffer(width: width, height: height) else {
            print("error: cannot allocate buffers")
            return 1
        }
        let context = CIContext()
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        context.render(scaled, to: input, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: sRGB)

        do {
            let processor = try FrameProcessor(modelDirectory: Bundle.main.resourcePath ?? "")
            processor.debugOverlay = rest.contains("--debug")
            let masks = PersonSegmenter().masks(for: input)
            var info: viracm_frame_info?
            for frame in 0..<15 {
                info = processor.process(input, into: output, timestamp: Double(frame) / 30, masks: masks)
            }
            guard let info else {
                print("error: processing failed")
                return 1
            }
            print("\(width)x\(height)  mode=\(info.mode == VIRACM_FRAME_PROTECTED ? "protected" : "full_blur")",
                  "people=\(masks.count)  outline=\(info.used_person_mask != 0)",
                  "faces_detected=\(info.faces_detected)  faces_blurred=\(info.faces_blurred)")
            try context.writePNGRepresentation(of: CIImage(cvPixelBuffer: output), to: URL(fileURLWithPath: paths[1]),
                                               format: .RGBA8, colorSpace: sRGB)
            return 0
        } catch {
            print("error: \(error.localizedDescription)")
            return 1
        }
    }

    private static func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        return buffer
    }
}
