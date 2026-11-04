import Foundation

/// Seconds to wait for ScreenCaptureKit (and replayd behind it) before giving up. SCREENCAP_SCK_TIMEOUT overrides.
let sckTimeout: Double = {
    guard let raw = ProcessInfo.processInfo.environment["SCREENCAP_SCK_TIMEOUT"], let s = Double(raw), 0 < s else { return 15 }
    return s
}()

struct SCKTimeout: Error, CustomStringConvertible {
    let what: String
    let seconds: Double

    var description: String {
        "ScreenCaptureKit/replayd did not respond to \(what) within \(String(format: "%g", seconds))s; replayd may be wedged. "
            + "Stop and tell the user rather than retrying."
    }
}

/// Runs `op`, throwing SCKTimeout if it hasn't finished after `seconds`.
/// ScreenCaptureKit awaits ignore task cancellation, so a task group would wait out the hung call; this
/// resumes on whichever finishes first and abandons the other.
func withSCKTimeout<T>(_ what: String, seconds: Double = sckTimeout, _ op: @escaping () async throws -> T) async throws -> T {
    let gate = ResumeOnce<T>()
    return try await withCheckedThrowingContinuation { cont in
        gate.set(cont)
        Task {
            do { gate.resume(.success(try await op())) } catch { gate.resume(.failure(error)) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            gate.resume(.failure(SCKTimeout(what: what, seconds: seconds)))
        }
    }
}

private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?

    func set(_ c: CheckedContinuation<T, Error>) {
        lock.lock()
        cont = c
        lock.unlock()
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(with: result)
    }
}

struct ProcessResult {
    let status: Int32
    let stdout: Data
    let timedOut: Bool
}

/// Runs an executable to completion, SIGKILLing it after `timeout` seconds. stderr is inherited.
func runProcess(_ path: String, _ arguments: [String], stdin: Data? = nil, timeout: Double) async throws -> ProcessResult {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = arguments
    let out = Pipe()
    proc.standardOutput = out
    let input = Pipe()
    proc.standardInput = stdin == nil ? FileHandle.nullDevice : input

    let state = ProcessState()
    return try await withCheckedThrowingContinuation { cont in
        let reading = DispatchGroup()
        reading.enter()
        proc.terminationHandler = { p in
            reading.notify(queue: .global()) {
                cont.resume(returning: ProcessResult(status: p.terminationStatus, stdout: state.output, timedOut: state.timedOut))
            }
        }
        do {
            try proc.run()
        } catch {
            cont.resume(throwing: ToolError("Could not run \(path): \(error.localizedDescription)"))
            return
        }
        DispatchQueue.global().async {
            state.output = out.fileHandleForReading.readDataToEndOfFile()
            reading.leave()
        }
        if let stdin {
            DispatchQueue.global().async {
                try? input.fileHandleForWriting.write(contentsOf: stdin)
                try? input.fileHandleForWriting.close()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard proc.isRunning else { return }
            state.timedOut = true
            kill(proc.processIdentifier, SIGKILL)
        }
    }
}

private final class ProcessState: @unchecked Sendable {
    var output = Data()
    var timedOut = false
}
