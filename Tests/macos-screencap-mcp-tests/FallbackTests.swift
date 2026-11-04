import XCTest
@testable import macos_screencap_mcp

final class FallbackTests: XCTestCase {
    func testSkyLightCaptureIsAvailableOnThisMacOS() {
        XCTAssertTrue(SkyLight.isAvailable, "CGSHWCaptureWindowList or CGSMainConnectionID is missing from SkyLight")
    }

    func testNoteNamesTheMethodAndTheTimeout() {
        let cause = SCKTimeout(what: "screenshot_window", seconds: 15)
        XCTAssertEqual(Fallback.note(cause, via: "CGSHWCaptureWindowList"),
                       "Captured with CGSHWCaptureWindowList because screenshot_window timed out after 15s in ScreenCaptureKit.")
        XCTAssertTrue(Fallback.note(cause).hasPrefix("Captured with /usr/sbin/screencapture because"))
    }

    func testSkyLightWorkerToolHasTheNameTheFallbackRuns() {
        XCTAssertEqual(Fallback.skyLightWindowTool.name, Fallback.skyLightTool)
    }

    func testUnknownWindowIDIsReported() {
        XCTAssertThrowsError(try Fallback.cgWindow(["window_id": Int(Int32.max)])) {
            XCTAssertTrue("\($0)".contains("No window with id"))
        }
    }
}
