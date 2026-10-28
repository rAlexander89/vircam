import AVFoundation
import SwiftUI

/// Shows processed frames, i.e. exactly what calling apps receive.
final class PreviewRenderer {
    let layer = AVSampleBufferDisplayLayer()

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
    }

    /// Safe to call from any queue.
    func display(_ pixelBuffer: CVPixelBuffer) {
        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: pixelBuffer,
                                                     formatDescriptionOut: &formatDescription)
        guard let formatDescription else { return }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                 imageBuffer: pixelBuffer,
                                                 formatDescription: formatDescription,
                                                 sampleTiming: &timing,
                                                 sampleBufferOut: &sampleBuffer)
        guard let sampleBuffer else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
        }
        renderer.enqueue(sampleBuffer)
    }

    func clear() {
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }
}

struct PreviewView: NSViewRepresentable {
    let renderer: PreviewRenderer

    func makeNSView(context: Context) -> NSView {
        MirroredLayerView(contentLayer: renderer.layer)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Shows a layer flipped horizontally, like the self-view in Zoom and Meet. Only the
/// preview is mirrored; video sent to calling apps is not, so others see you unflipped.
private final class MirroredLayerView: NSView {
    private let contentLayer: CALayer

    init(contentLayer: CALayer) {
        self.contentLayer = contentLayer
        super.init(frame: .zero)
        wantsLayer = true
        contentLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        layer?.addSublayer(contentLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        // `frame` is undefined while a transform is set; position via bounds instead.
        contentLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        contentLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}
