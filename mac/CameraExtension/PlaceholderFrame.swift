import CoreGraphics
import CoreText
import CoreVideo
import Foundation

/// The frame calling apps see when the Vircam app is not sending video.
enum PlaceholderFrame {
    static func make(width: Int, height: Int) -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, VirtualCamera.pixelFormat, attributes, &pixelBuffer)
        guard let pixelBuffer else { fatalError("Failed to allocate placeholder frame") }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer),
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: bitmapInfo) else {
            fatalError("Failed to create placeholder context")
        }

        context.setFillColor(CGColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        drawCentered("Vircam is not running", size: CGFloat(height) / 16, alpha: 0.9,
                     y: CGFloat(height) * 0.52, in: context, width: width)
        drawCentered("Open the Vircam app to turn on your camera", size: CGFloat(height) / 32, alpha: 0.55,
                     y: CGFloat(height) * 0.44, in: context, width: width)
        return pixelBuffer
    }

    private static func drawCentered(_ text: String, size: CGFloat, alpha: CGFloat, y: CGFloat,
                                     in context: CGContext, width: Int) {
        let font = CTFontCreateUIFontForLanguage(.system, size, nil)!
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: alpha),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textPosition = CGPoint(x: (CGFloat(width) - lineWidth) / 2, y: y)
        CTLineDraw(line, context)
    }
}
