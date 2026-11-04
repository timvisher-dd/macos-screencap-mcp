import XCTest
@testable import macos_screencap_mcp

final class SingleFlightTests: XCTestCase {
    /// Holds fetch callbacks until the test delivers them.
    final class Pending: @unchecked Sendable {
        private let lock = NSLock()
        private var callbacks: [(Result<Int, Error>) -> Void] = []

        func add(_ cb: @escaping (Result<Int, Error>) -> Void) {
            lock.lock()
            callbacks.append(cb)
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return callbacks.count
        }

        func deliver(_ index: Int, _ result: Result<Int, Error>) {
            lock.lock()
            let cb = callbacks[index]
            lock.unlock()
            cb(result)
        }
    }

    func waitFor(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            guard Date() < deadline else { return XCTFail("condition never became true") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testConcurrentCallersShareOneFetch() async throws {
        let pending = Pending()
        let flight = SingleFlight<Int>("test", watchdog: 5) { pending.add($0) }
        async let a = flight.value()
        async let b = flight.value()
        async let c = flight.value()
        try await waitFor { pending.count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        pending.deliver(0, .success(7))
        let results = try await [a, b, c]
        XCTAssertEqual(results, [7, 7, 7])
        XCTAssertEqual(flight.fetchCount, 1)
    }

    func testANewFetchStartsAfterTheLastOneFinished() async throws {
        let flight = SingleFlight<Int>("test", watchdog: 5) { $0(.success(1)) }
        _ = try await flight.value()
        _ = try await flight.value()
        XCTAssertEqual(flight.fetchCount, 2)
    }

    func testWatchdogExpiresALostCallbackAndTheNextCallerRefetches() async throws {
        let pending = Pending()
        let flight = SingleFlight<Int>("lost", watchdog: 0.2) { pending.add($0) }
        let start = Date()
        do {
            _ = try await flight.value()
            XCTFail("expected a timeout")
        } catch let timeout as SCKTimeout {
            XCTAssertEqual(timeout.what, "lost")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)

        async let next = flight.value()
        try await waitFor { pending.count == 2 }
        pending.deliver(0, .success(99))
        pending.deliver(1, .success(2))
        let value = try await next
        XCTAssertEqual(value, 2)
        XCTAssertEqual(flight.fetchCount, 2)
    }

    func testErrorsReachEveryWaiter() async throws {
        let pending = Pending()
        let flight = SingleFlight<Int>("test", watchdog: 5) { pending.add($0) }
        async let a = flight.value()
        async let b = flight.value()
        try await waitFor { pending.count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        pending.deliver(0, .failure(ToolError("boom")))
        do {
            _ = try await a
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual("\(error)", "boom")
        }
        do {
            _ = try await b
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual("\(error)", "boom")
        }
    }
}
