import Foundation

/// Each slot is a file locked with flock(2) rather than a lock directory or pid file: the kernel drops the lock when
/// its holder exits, even on SIGKILL, so a killed worker or server never strands a slot.
enum CaptureSlots {
    /// SCREENCAP_MAX_CAPTURES overrides. 1, not AltTab's 2: AltTab's two share one process, but two workers in
    /// separate processes starting at once made replayd stall discovery and fail TCC checks on macOS 26.7.
    static let limit: Int = {
        guard let raw = ProcessInfo.processInfo.environment["SCREENCAP_MAX_CAPTURES"], let n = Int(raw), 0 < n else { return 1 }
        return n
    }()

    static let wait: Double = {
        guard let raw = ProcessInfo.processInfo.environment["SCREENCAP_SLOT_WAIT"], let s = Double(raw), 0 < s else { return 2 * sckTimeout }
        return s
    }()

    static var directory: URL {
        let env = ProcessInfo.processInfo.environment
        let base = env["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state")
        return base.appendingPathComponent("macos-screencap-mcp")
    }

    final class Slot: @unchecked Sendable {
        let index: Int
        private var fd: Int32

        init(index: Int, fd: Int32) {
            self.index = index
            self.fd = fd
        }

        func release() {
            guard 0 <= fd else { return }
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }

        deinit { release() }
    }

    struct Busy: Error, CustomStringConvertible {
        let limit: Int
        let waited: Double

        var description: String {
            "\(limit) other screen capture\(limit == 1 ? " is" : "s are") already running on this machine and none finished "
                + "within \(String(format: "%g", waited))s. Stop and tell the user rather than retrying."
        }
    }

    static func acquire(limit: Int = limit, directory: URL = directory, wait: Double = wait) async throws -> Slot {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let deadline = Date().addingTimeInterval(wait)
        while true {
            for i in 0..<limit {
                if let slot = try tryLock(i, in: directory) { return slot }
            }
            guard Date() < deadline else { throw Busy(limit: limit, waited: wait) }
            try await Task.sleep(for: .milliseconds(Int.random(in: 50...150)))
        }
    }

    private static func tryLock(_ index: Int, in directory: URL) throws -> Slot? {
        let path = directory.appendingPathComponent("capture-slot-\(index).lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard 0 <= fd else { throw ToolError("Cannot open \(path): \(String(cString: strerror(errno)))") }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return Slot(index: index, fd: fd) }
        let err = errno
        close(fd)
        guard err == EWOULDBLOCK else { throw ToolError("Cannot lock \(path): \(String(cString: strerror(err)))") }
        return nil
    }
}
