import CoreMediaIO
import Foundation
import os.log

let logger = Logger(subsystem: "dev.vircam.CameraExtension", category: "camera")

/// The Vircam Camera device. It has two streams:
/// - a sink stream the Vircam app pushes processed frames into, and
/// - a source stream calling apps read from.
/// Calling apps only ever see frames from the Vircam app, or the placeholder when the
/// app is not sending. The extension never touches the real camera.
final class CameraProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: CameraDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = CameraDeviceSource()
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}

    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = VirtualCamera.manufacturer
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

final class CameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var sourceStream: SourceStreamSource!
    private var sinkStream: SinkStreamSource!

    private let frameDuration = CMTime(value: 1, timescale: VirtualCamera.frameRate)
    private var formatDescription: CMVideoFormatDescription!
    private var placeholder: CVPixelBuffer!

    // Everything below is only accessed on `queue`.
    private let queue = DispatchQueue(label: "dev.vircam.camera.frames", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var sourceClientCount = 0
    private var sinkClient: CMIOExtensionClient?
    private var consumeInFlight = false
    private var latestFrame: CVPixelBuffer?
    private var latestFrameHostTime: UInt64 = 0

    override init() {
        super.init()
        device = CMIOExtensionDevice(localizedName: VirtualCamera.deviceName,
                                     deviceID: VirtualCamera.deviceID,
                                     legacyDeviceID: nil,
                                     source: self)

        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                       codecType: VirtualCamera.pixelFormat,
                                       width: VirtualCamera.width,
                                       height: VirtualCamera.height,
                                       extensions: nil,
                                       formatDescriptionOut: &description)
        formatDescription = description
        placeholder = PlaceholderFrame.make(width: Int(VirtualCamera.width), height: Int(VirtualCamera.height))

        let format = CMIOExtensionStreamFormat(formatDescription: formatDescription,
                                               maxFrameDuration: frameDuration,
                                               minFrameDuration: frameDuration,
                                               validFrameDurations: nil)
        let appSigningID = Bundle.main.object(forInfoDictionaryKey: "VircamAppSigningIdentifier") as? String
        sourceStream = SourceStreamSource(format: format, frameDuration: frameDuration, device: self)
        sinkStream = SinkStreamSource(format: format, frameDuration: frameDuration,
                                      allowedSigningID: appSigningID, device: self)
        do {
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            fatalError("Failed to add streams: \(error)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = Int(VirtualCamera.virtualTransportType)
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = VirtualCamera.deviceModel
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: Stream lifecycle

    func sourceStarted() {
        queue.async {
            self.sourceClientCount += 1
            self.updateTimer()
        }
    }

    func sourceStopped() {
        queue.async {
            self.sourceClientCount = max(0, self.sourceClientCount - 1)
            self.updateTimer()
        }
    }

    func sinkStarted(client: CMIOExtensionClient) {
        queue.async {
            self.sinkClient = client
            self.updateTimer()
        }
    }

    func sinkStopped() {
        queue.async {
            self.sinkClient = nil
            self.latestFrame = nil
            self.updateTimer()
        }
    }

    private func updateTimer() {
        let needed = sourceClientCount > 0 || sinkClient != nil
        if needed, timer == nil {
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            timer.schedule(deadline: .now(), repeating: frameDuration.seconds, leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        } else if !needed, let timer {
            timer.cancel()
            self.timer = nil
        }
    }

    // MARK: Frames

    private func tick() {
        if let sinkClient, !consumeInFlight {
            consume(from: sinkClient)
        }
        guard sourceClientCount > 0 else { return }

        let now = hostTimeNanoseconds()
        let maxAge = UInt64(VirtualCamera.staleFrameInterval * Double(NSEC_PER_SEC))
        if let latestFrame, now - latestFrameHostTime < maxAge {
            send(latestFrame, hostTime: now)
        } else {
            send(placeholder, hostTime: now)
        }
    }

    private func consume(from client: CMIOExtensionClient) {
        consumeInFlight = true
        sinkStream.stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, sequenceNumber, _, hasMoreSampleBuffers, error in
            guard let self else { return }
            self.queue.async {
                self.consumeInFlight = false
                guard error == nil, let sampleBuffer, self.sinkClient === client else { return }

                let now = hostTimeNanoseconds()
                if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer), self.matchesFormat(pixelBuffer) {
                    self.latestFrame = pixelBuffer
                    self.latestFrameHostTime = now
                } else {
                    logger.error("Dropped frame with unexpected format from app")
                }
                let output = CMIOExtensionScheduledOutput(sequenceNumber: sequenceNumber, hostTimeInNanoseconds: now)
                self.sinkStream.stream.notifyScheduledOutputChanged(output)

                // Drain queued frames so we always show the newest one.
                if hasMoreSampleBuffers {
                    self.consume(from: client)
                }
            }
        }
    }

    private func matchesFormat(_ pixelBuffer: CVPixelBuffer) -> Bool {
        CVPixelBufferGetWidth(pixelBuffer) == Int(VirtualCamera.width)
            && CVPixelBufferGetHeight(pixelBuffer) == Int(VirtualCamera.height)
            && CVPixelBufferGetPixelFormatType(pixelBuffer) == VirtualCamera.pixelFormat
    }

    private func send(_ pixelBuffer: CVPixelBuffer, hostTime: UInt64) {
        var timing = CMSampleTimingInfo(duration: frameDuration,
                                        presentationTimeStamp: CMTime(value: CMTimeValue(hostTime), timescale: 1_000_000_000),
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                        imageBuffer: pixelBuffer,
                                                        dataReady: true,
                                                        makeDataReadyCallback: nil,
                                                        refcon: nil,
                                                        formatDescription: formatDescription,
                                                        sampleTiming: &timing,
                                                        sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else {
            logger.error("Failed to create sample buffer: \(status)")
            return
        }
        sourceStream.stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: hostTime)
    }
}

/// The stream calling apps (Zoom, Meet, ...) read from.
final class SourceStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private let frameDuration: CMTime
    private unowned let device: CameraDeviceSource

    init(format: CMIOExtensionStreamFormat, frameDuration: CMTime, device: CameraDeviceSource) {
        self.format = format
        self.frameDuration = frameDuration
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: "Vircam Video",
                                     streamID: VirtualCamera.sourceStreamID,
                                     direction: .source,
                                     clockType: .hostTime,
                                     source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = frameDuration
        }
        return streamProperties
    }

    // There is a single format and frame rate, so there is nothing to change.
    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws { device.sourceStarted() }

    func stopStream() throws { device.sourceStopped() }
}

/// The stream the Vircam app writes processed frames into. Only the Vircam app may
/// write to it, so no other process can inject video into the camera.
final class SinkStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private let frameDuration: CMTime
    private let allowedSigningID: String?
    private unowned let device: CameraDeviceSource
    private var authorizedClient: CMIOExtensionClient?

    init(format: CMIOExtensionStreamFormat, frameDuration: CMTime, allowedSigningID: String?, device: CameraDeviceSource) {
        self.format = format
        self.frameDuration = frameDuration
        self.allowedSigningID = allowedSigningID
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: "Vircam Input",
                                     streamID: VirtualCamera.sinkStreamID,
                                     direction: .sink,
                                     clockType: .hostTime,
                                     source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration,
         .streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup,
         .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = frameDuration
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            streamProperties.sinkBufferQueueSize = 1
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            streamProperties.sinkBuffersRequiredForStartup = 1
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        guard let allowedSigningID, client.signingID == allowedSigningID else {
            logger.error("Rejected sink client \(client.signingID ?? "unsigned", privacy: .public)")
            return false
        }
        authorizedClient = client
        return true
    }

    func startStream() throws {
        guard let authorizedClient else { return }
        device.sinkStarted(client: authorizedClient)
    }

    func stopStream() throws {
        authorizedClient = nil
        device.sinkStopped()
    }
}

func hostTimeNanoseconds() -> UInt64 {
    let now = CMClockGetTime(CMClockGetHostTimeClock())
    return UInt64(CMTimeConvertScale(now, timescale: 1_000_000_000, method: .default).value)
}
