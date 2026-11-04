import XCTest
@testable import macos_screencap_mcp

final class TimeoutTests: XCTestCase {
    func testReturnsResultBeforeTimeout() async throws {
        let value = try await withSCKTimeout("fast", seconds: 5) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testThrowsWhenOperationNeverFinishes() async throws {
        let start = Date()
        do {
            _ = try await withSCKTimeout("never", seconds: 0.2) { () async throws -> Int in
                try? await Task.sleep(for: .seconds(30))
                return 0
            }
            XCTFail("expected a timeout")
        } catch let timeout as SCKTimeout {
            XCTAssertEqual(timeout.what, "never")
            XCTAssertTrue(timeout.description.contains("did not respond to never within 0.2s"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testPassesThroughErrors() async {
        do {
            _ = try await withSCKTimeout("failing", seconds: 5) { () async throws -> Int in throw ToolError("boom") }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual("\(error)", "boom")
        }
    }

    func testRunProcessCapturesStdoutAndFeedsStdin() async throws {
        let result = try await runProcess("/bin/cat", [], stdin: Data("hello".utf8), timeout: 5)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "hello")
    }

    func testRunProcessKillsOnTimeout() async throws {
        let start = Date()
        let result = try await runProcess("/bin/sleep", ["30"], timeout: 0.3)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.status, SIGKILL)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}
