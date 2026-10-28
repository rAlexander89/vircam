import CoreMedia
import CoreMediaIO
import Foundation

/// Pushes processed frames into the Vircam Camera extension's sink stream using the
/// CoreMediaIO hardware API. Not thread-safe: call from one queue.
final class VirtualCameraOutput {
    private var deviceID: CMIODeviceID = 0
    private var streamID: CMIOStreamID = 0
    private var queue: CMSimpleQueue?

    var isConnected: Bool { queue != nil }

    /// Finds the Vircam Camera device and starts its sink stream. Returns false if the
    /// extension is not installed or not running.
    @discardableResult
    func connect() -> Bool {
        if isConnected { return true }
        guard let device = Self.findDevice(), let sink = Self.findSinkStream(of: device) else { return false }

        var queueRef: Unmanaged<CMSimpleQueue>?
        let status = CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &queueRef)
        guard status == noErr, let queue = queueRef?.takeRetainedValue() else { return false }
        guard CMIODeviceStartStream(device, sink) == noErr else { return false }

        deviceID = device
        streamID = sink
        self.queue = queue
        return true
    }

    func disconnect() {
        guard isConnected else { return }
        CMIODeviceStopStream(deviceID, streamID)
        queue = nil
    }

    func send(_ pixelBuffer: CVPixelBuffer) {
        guard let queue else { return }
        // If the extension is not keeping up, drop the frame; it shows the newest it has.
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { return }

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

        let element = Unmanaged.passRetained(sampleBuffer).toOpaque()
        if CMSimpleQueueEnqueue(queue, element: element) != noErr {
            Unmanaged<CMSampleBuffer>.fromOpaque(element).release()
            // The extension probably restarted; reconnect on the next attempt.
            disconnect()
        }
    }

    // MARK: CoreMediaIO lookups

    private static func findDevice() -> CMIODeviceID? {
        objectIDs(of: CMIOObjectID(kCMIOObjectSystemObject), selector: kCMIOHardwarePropertyDevices).first { device in
            stringProperty(of: device, selector: kCMIODevicePropertyDeviceUID) == VirtualCamera.deviceID.uuidString
                || stringProperty(of: device, selector: kCMIOObjectPropertyName) == VirtualCamera.deviceName
        }
    }

    private static func findSinkStream(of device: CMIODeviceID) -> CMIOStreamID? {
        // kCMIOStreamPropertyDirection: 0 = output (sink), 1 = input (source).
        objectIDs(of: device, selector: kCMIODevicePropertyStreams).first { stream in
            uint32Property(of: stream, selector: kCMIOStreamPropertyDirection) == 0
        }
    }

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func objectIDs(of object: CMIOObjectID, selector: Int) -> [CMIOObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    private static func stringProperty(of object: CMIOObjectID, selector: Int) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func uint32Property(of object: CMIOObjectID, selector: Int) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == noErr
        else { return nil }
        return value
    }
}
