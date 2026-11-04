import Foundation

/// Seconds to wait for an SCShareableContent callback before expiring it. SCREENCAP_DISCOVERY_TIMEOUT overrides.
let discoveryTimeout: Double = {
    guard let raw = ProcessInfo.processInfo.environment["SCREENCAP_DISCOVERY_TIMEOUT"], let s = Double(raw), 0 < s else { return 5 }
    return s
}()

/// Runs at most one `fetch` at a time; callers that arrive while one is in flight wait for its result rather than
/// starting another. A fetch whose callback hasn't come back after `watchdog` seconds is expired: its waiters get
/// SCKTimeout, the next caller starts a fresh fetch, and the lost callback is ignored if it ever arrives.
final class SingleFlight<T>: @unchecked Sendable {
    typealias Fetch = (@escaping (Result<T, Error>) -> Void) -> Void

    let what: String
    let watchdog: Double
    private let fetch: Fetch
    private let lock = NSLock()
    private var generation = 0
    private var inFlight = false
    private var waiters: [CheckedContinuation<T, Error>] = []
    private var started = 0

    init(_ what: String, watchdog: Double, fetch: @escaping Fetch) {
        self.what = what
        self.watchdog = watchdog
        self.fetch = fetch
    }

    /// How many fetches have been started.
    var fetchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    func value() async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            waiters.append(cont)
            if inFlight {
                lock.unlock()
                return
            }
            inFlight = true
            generation += 1
            started += 1
            let gen = generation
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + watchdog) { [self] in
                finish(gen, .failure(SCKTimeout(what: what, seconds: watchdog)))
            }
            fetch { [self] result in finish(gen, result) }
        }
    }

    private func finish(_ gen: Int, _ result: Result<T, Error>) {
        lock.lock()
        guard inFlight, gen == generation else {
            lock.unlock()
            return
        }
        inFlight = false
        let done = waiters
        waiters = []
        lock.unlock()
        for w in done { w.resume(with: result) }
    }
}
