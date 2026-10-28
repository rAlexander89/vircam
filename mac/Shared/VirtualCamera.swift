import CoreVideo
import Foundation

/// Identity and video format of the "Vircam Camera" device, shared by the app and the
/// camera extension. IDs are fixed so calling apps remember the selected camera.
enum VirtualCamera {
    static let deviceName = "Vircam Camera"
    static let deviceModel = "Vircam Privacy Camera"
    static let manufacturer = "Vircam"

    static let deviceID = UUID(uuidString: "B2C359E2-B0F0-4CF3-9D9F-C735DBFEF749")!
    static let sourceStreamID = UUID(uuidString: "3CFDC5F0-E85B-4F93-8761-A178D2388665")!
    static let sinkStreamID = UUID(uuidString: "4769CEDF-5C1D-400A-AAD7-0B3A510695EC")!

    static let width: Int32 = 1280
    static let height: Int32 = 720
    static let frameRate: Int32 = 30
    static let pixelFormat: OSType = kCVPixelFormatType_32BGRA

    /// A frame from the app older than this is not shown; the camera shows the
    /// "not running" placeholder instead, so a stalled app never freezes on stale video.
    static let staleFrameInterval: TimeInterval = 0.5

    /// IOKit's kIOAudioDeviceTransportTypeVirtual ('virt'), used to mark and detect virtual cameras.
    static let virtualTransportType: UInt32 = 0x7669_7274
}
