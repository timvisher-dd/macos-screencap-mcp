import XCTest
@testable import macos_screencap_mcp

final class CaptureSlotsTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("capture-slots-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testHandsOutUpToTheLimitThenReportsBusy() async throws {
        let a = try await CaptureSlots.acquire(limit: 2, directory: dir, wait: 0.2)
        let b = try await CaptureSlots.acquire(limit: 2, directory: dir, wait: 0.2)
        XCTAssertEqual(Set([a.index, b.index]), [0, 1])
        let start = Date()
        do {
            _ = try await CaptureSlots.acquire(limit: 2, directory: dir, wait: 0.2)
            XCTFail("expected Busy")
        } catch let busy as CaptureSlots.Busy {
            XCTAssertEqual(busy.limit, 2)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        a.release()
        b.release()
    }

    func testAWaiterGetsTheSlotWhenItIsReleased() async throws {
        let held = try await CaptureSlots.acquire(limit: 1, directory: dir, wait: 0.2)
        let dir = self.dir!
        let waiter = Task { try await CaptureSlots.acquire(limit: 1, directory: dir, wait: 5) }
        try await Task.sleep(for: .milliseconds(300))
        held.release()
        let slot = try await waiter.value
        XCTAssertEqual(slot.index, 0)
        slot.release()
    }

    func testAnotherProcessHoldingTheSlotCounts() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lockFile = dir.appendingPathComponent("capture-slot-0.lock").path
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = ["-MFcntl=:flock", "-e", "open(F, '>>', $ARGV[0]) or die; flock(F, LOCK_EX) or die; print qq(locked\\n); $| = 1; sleep 30", lockFile]
        let out = Pipe()
        holder.standardOutput = out
        try holder.run()
        defer { holder.terminate() }
        _ = out.fileHandleForReading.availableData

        do {
            _ = try await CaptureSlots.acquire(limit: 1, directory: dir, wait: 0.2)
            XCTFail("expected Busy while another process holds the slot")
        } catch is CaptureSlots.Busy {}

        kill(holder.processIdentifier, SIGKILL)
        holder.waitUntilExit()
        let slot = try await CaptureSlots.acquire(limit: 1, directory: dir, wait: 2)
        XCTAssertEqual(slot.index, 0)
        slot.release()
    }

    func testReleaseIsIdempotent() async throws {
        let slot = try await CaptureSlots.acquire(limit: 1, directory: dir, wait: 0.2)
        slot.release()
        slot.release()
        let again = try await CaptureSlots.acquire(limit: 1, directory: dir, wait: 0.2)
        again.release()
    }
}
