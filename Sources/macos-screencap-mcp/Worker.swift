import AppKit
import CoreGraphics

/// Listing and screenshot tools run in a short-lived copy of this binary (`--worker <tool>`), not in the server.
/// Once a process has talked to ScreenCaptureKit, ReplayKit keeps a connection to replayd for the life of the
/// process. If replayd stops answering a request, that connection reconnects on every drop, hundreds of times a
/// second, and the request can never be cancelled. A worker owns the connection instead: it exits when the call
/// is done, or is SIGKILLed when the call times out, so an idle server holds nothing and a hung call can't
/// outlive its timeout.
enum Worker {
    static let flag = "--worker"

    static func run(_ tool: String, _ args: JSON) async throws -> [JSON] {
        guard let exe = Bundle.main.executablePath else { throw ToolError("Cannot locate the server executable.") }
        let input = try JSONSerialization.data(withJSONObject: args)
        let result = try await runProcess(exe, [flag, tool], stdin: input, timeout: sckTimeout)
        if result.timedOut { throw SCKTimeout(what: tool, seconds: sckTimeout) }
        guard let reply = (try? JSONSerialization.jsonObject(with: result.stdout)) as? JSON else {
            throw ToolError("\(tool) worker exited with status \(result.status) and no reply.")
        }
        if let what = reply["timeout"] as? String {
            throw SCKTimeout(what: what, seconds: reply["timeout_seconds"] as? Double ?? sckTimeout)
        }
        if let error = reply["error"] as? String { throw ToolError(error) }
        return reply["content"] as? [JSON] ?? []
    }

    /// Worker side: reads the tool's arguments as JSON on stdin and writes `{"content": [...]}` or `{"error": "..."}`,
    /// plus `timeout` and `timeout_seconds` when the error is an SCKTimeout.
    static func serve(_ tool: String, from tools: [Tool]) -> Never {
        let args = (try? JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile())) as? JSON ?? [:]
        Task {
            var reply: JSON
            if let t = tools.first(where: { $0.name == tool }) {
                do {
                    reply = ["content": try await t.handler(args)]
                } catch let timeout as SCKTimeout {
                    reply = ["error": "\(timeout)", "timeout": timeout.what, "timeout_seconds": timeout.seconds]
                } catch {
                    reply = ["error": "\(error)"]
                }
            } else {
                reply = ["error": "Unknown worker tool \(tool)"]
            }
            FileHandle.standardOutput.write((try? JSONSerialization.data(withJSONObject: reply)) ?? Data())
            exit(0)
        }
        dispatchMain()
    }

    /// Wraps an in-process tool so the server runs it in a worker, falling back to `fallback` on timeout.
    static func wrap(_ t: Tool, fallback: ((JSON, SCKTimeout) async throws -> [JSON])?) -> Tool {
        Tool(name: t.name, description: t.description, inputSchema: t.inputSchema) { args in
            // The user may take any amount of time to drag out a selection, and it doesn't use ScreenCaptureKit.
            if args.bool("interactive") == true { return try await t.handler(args) }
            // The worker exits as soon as it replies, which would cut the sound off.
            var workerArgs = args
            workerArgs["shutter_sound"] = nil
            let content: [JSON]
            do {
                content = try await run(t.name, workerArgs)
            } catch let timeout as SCKTimeout {
                log("\(timeout)")
                guard let fallback else { throw timeout }
                content = try await fallback(args, timeout)
            }
            if args.bool("shutter_sound") == true { Capture.playShutter() }
            return content
        }
    }
}

/// /usr/sbin/screencapture, used when ScreenCaptureKit times out. It doesn't share this process's replayd
/// connection, but it may still depend on replayd, so it gets a timeout too.
enum Fallback {
    static let timeout: Double = 15

    static func window(_ args: JSON, _ cause: SCKTimeout) async throws -> [JSON] {
        let info = try cgWindow(args)
        let id = (info[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0
        let owner = info[kCGWindowOwnerName as String] as? String
        let title = info[kCGWindowName as String] as? String
        let ext = requestedExt(args, ["png", "jpg"], default: "png")
        let url = try outputURL(args.string("output_path"), name: args.string("name"), fallback: [owner, title], ext: ext)
        try await screencapture(["-o", "-l", "\(id)"], ext: ext, to: url, cause: cause)
        let window: JSON = ["window_id": id, "app": owner ?? "", "title": title ?? ""]
        return screenshotResult(try Capture.loadImage(url), url: url, extra: ["window": window, "fallback": note(cause)],
                                includeImage: args.bool("include_image") ?? true)
    }

    static func region(_ args: JSON, _ cause: SCKTimeout) async throws -> [JSON] {
        let given = ["x", "y", "width", "height"].compactMap { args.double($0) }
        guard given.isEmpty || given.count == 4 else {
            throw ToolError("Provide all of x, y, width, height, or none to capture the whole display.")
        }
        var rect = given.count == 4 ? CGRect(x: given[0], y: given[1], width: given[2], height: given[3]) : nil
        if let id = args.int("display_id") {
            let bounds = CGDisplayBounds(CGDirectDisplayID(id))
            rect = rect.map { $0.intersection(bounds) } ?? bounds
        }
        let r = (rect ?? CGDisplayBounds(CGMainDisplayID())).integral
        guard !r.isNull, 1 <= r.width, 1 <= r.height else { throw ToolError("Rectangle does not overlap the display.") }
        let ext = requestedExt(args, ["png", "jpg"], default: "png")
        let url = try outputURL(args.string("output_path"), name: args.string("name"), fallback: ["region"], ext: ext)
        var flags = ["-R", "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))"]
        if args.bool("show_cursor") == true { flags.append("-C") }
        try await screencapture(flags, ext: ext, to: url, cause: cause)
        return screenshotResult(try Capture.loadImage(url), url: url, extra: ["rect": rectJSON(r), "fallback": note(cause)],
                                includeImage: args.bool("include_image") ?? true)
    }

    private static func note(_ cause: SCKTimeout) -> String {
        "Captured with /usr/sbin/screencapture because \(cause.what) timed out after \(String(format: "%g", cause.seconds))s in ScreenCaptureKit."
    }

    private static func screencapture(_ flags: [String], ext: String, to url: URL, cause: SCKTimeout) async throws {
        let result = try await runProcess("/usr/sbin/screencapture", ["-x", "-t", ext] + flags + [url.path], timeout: timeout)
        if result.timedOut {
            throw ToolError("\(cause) The /usr/sbin/screencapture fallback also timed out after \(String(format: "%g", timeout))s.")
        }
        guard result.status == 0, FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError("\(cause) The /usr/sbin/screencapture fallback failed with status \(result.status).")
        }
    }

    /// The window to capture, found with CoreGraphics so it doesn't touch ScreenCaptureKit.
    private static func cgWindow(_ args: JSON) throws -> JSON {
        let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [JSON] ?? []
        if let id = args.int("window_id") {
            guard let w = all.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == id }) else {
                throw ToolError("No window with id \(id).")
            }
            return w
        }
        let app = args.string("app")?.lowercased()
        let title = args.string("title")?.lowercased()
        guard app != nil || title != nil else { throw ToolError("Provide window_id, or app and/or title to match a window.") }
        let match = all.first { w in
            guard (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = (w[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  40 <= bounds.width, 40 <= bounds.height,
                  (w[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true
                    || !((w[kCGWindowName as String] as? String) ?? "").isEmpty
            else { return false }
            let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            let names = [w[kCGWindowOwnerName as String] as? String, NSRunningApplication(processIdentifier: pid)?.bundleIdentifier]
            let appOK = app.map { a in names.contains { $0?.lowercased().contains(a) == true } } ?? true
            let titleOK = title.map { t in (w[kCGWindowName as String] as? String)?.lowercased().contains(t) == true } ?? true
            return appOK && titleOK
        }
        guard let match else { throw ToolError("No window matched app=\(app ?? "*") title=\(title ?? "*").") }
        return match
    }
}
