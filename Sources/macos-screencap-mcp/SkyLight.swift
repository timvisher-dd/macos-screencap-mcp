import CoreGraphics
import Foundation

/// SkyLight's private CGSHWCaptureWindowList reads a window from WindowServer without replayd. It is looked up at
/// run time rather than linked so a macOS release that drops it disables the fallback instead of the binary.
enum SkyLight {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias HWCaptureWindowList = @convention(c) (Int32, UnsafeMutablePointer<UInt32>, UInt32, UInt32) -> Unmanaged<CFArray>?

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static let functions: (MainConnectionID, HWCaptureWindowList)? = {
        guard let handle, let conn = dlsym(handle, "CGSMainConnectionID"), let capture = dlsym(handle, "CGSHWCaptureWindowList") else {
            return nil
        }
        return (unsafeBitCast(conn, to: MainConnectionID.self), unsafeBitCast(capture, to: HWCaptureWindowList.self))
    }()

    static var isAvailable: Bool { functions != nil }

    static let ignoreGlobalClipShape: UInt32 = 1 << 11
    static let bestResolution: UInt32 = 1 << 8
    /// Keeps windows full size when Stage Manager would otherwise skew them.
    static let fullSize: UInt32 = 1 << 19

    static func captureWindow(_ id: CGWindowID) throws -> CGImage {
        guard let (mainConnection, capture) = functions else {
            throw ToolError("CGSHWCaptureWindowList is not available on this macOS.")
        }
        var windowID = id
        let images = capture(mainConnection(), &windowID, 1, ignoreGlobalClipShape | bestResolution | fullSize)?
            .takeRetainedValue() as? [CGImage]
        guard let image = images?.first else { throw ToolError("CGSHWCaptureWindowList returned no image for window \(id).") }
        return image
    }
}
