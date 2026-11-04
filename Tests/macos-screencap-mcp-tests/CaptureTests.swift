import XCTest
import ScreenCaptureKit
@testable import macos_screencap_mcp

final class CaptureTests: XCTestCase {
    func testPixelSizeScalesAndRoundsWithAFloorOfOne() {
        XCTAssertTrue(Capture.pixelSize(CGSize(width: 100.4, height: 50.6), scale: 2) == (201, 101))
        XCTAssertTrue(Capture.pixelSize(CGSize(width: 0, height: 0.1), scale: 2) == (1, 1))
    }

    func testScreenshotConfigurationCarriesTheRequest() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("captureScreenshot needs macOS 26") }
        let rect = CGRect(x: 10, y: 20, width: 300, height: 200)
        let config = Capture.screenshotConfiguration(pixels: (600, 400), sourceRect: rect, showCursor: false)
        XCTAssertEqual(config.width, 600)
        XCTAssertEqual(config.height, 400)
        XCTAssertEqual(config.sourceRect, rect)
        XCTAssertFalse(config.showsCursor)
        XCTAssertTrue(config.ignoreShadows)
        XCTAssertEqual(config.dynamicRange, .sdr)
    }

    func testScreenshotConfigurationLeavesSourceRectUnsetForWholeWindows() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("captureScreenshot needs macOS 26") }
        let config = Capture.screenshotConfiguration(pixels: (10, 10), sourceRect: nil, showCursor: true)
        XCTAssertEqual(config.sourceRect, SCScreenshotConfiguration().sourceRect)
        XCTAssertTrue(config.showsCursor)
    }
}
