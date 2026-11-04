# macos-screencap-mcp

[![npm](https://img.shields.io/npm/v/macos-screencap-mcp)](https://www.npmjs.com/package/macos-screencap-mcp)
[![license](https://img.shields.io/npm/l/macos-screencap-mcp)](LICENSE)

A local MCP server (stdio) for macOS that takes screenshots and records the screen. It is a single native Swift
binary built on ScreenCaptureKit and has no runtime dependencies.

With it, an agent such as Claude Code can:

- take a screenshot of a rectangle of the screen, a whole display, or one window (even when other windows cover it)
- let you drag-select an area to capture
- record a whole display or one window to MP4, either for a set time or from start to stop
- see what it captured, because screenshots are also returned inline as an image

Example requests to your agent:

> Take a screenshot of the Safari window and tell me what's wrong with the layout.
>
> Record my main display for 10 seconds.
>
> Start recording the Simulator window. … OK, stop recording.

## Requirements

- macOS 15 or later, on Apple Silicon or Intel
- Node.js, to run the server with `npx` (not needed if you build from source)
- **Screen Recording permission** for the app that launches the server (Terminal, iTerm, Claude Desktop, etc.):
  System Settings → Privacy & Security → Screen & System Audio Recording. Restart that app after granting it.

## Install

The [npm package](https://www.npmjs.com/package/macos-screencap-mcp) contains a prebuilt universal binary, so you
don't need Swift or Xcode.

### Claude Code

```bash
claude mcp add screencap --scope user -- npx -y macos-screencap-mcp
```

Then run `claude mcp list` to check that it connects, or `/mcp` inside a session.

The command has two halves, split by `--`:

- **Before `--` are options for Claude Code.** `screencap` is the name you give the server; its tools appear as
  `mcp__screencap__screenshot_window` and so on. `--scope user` makes it available in all your projects. Use
  `--scope project` to save it to the repo's `.mcp.json` and share it with everyone who clones the repo. Leave
  the option out to add it to the current project, for you only.
- **After `--` is the command Claude Code runs to start the server.** `npx` downloads the package and runs it.
  `-y` skips npx's "Ok to proceed?" prompt, which nobody would see and which would stall startup.

Options:

```bash
# Save captures somewhere other than ~/Desktop (-e goes before the --)
claude mcp add screencap --scope user -e SCREENCAP_OUTPUT_DIR=~/Screenshots -- npx -y macos-screencap-mcp

# Lock a specific version, or always fetch the newest with @latest
claude mcp add screencap --scope user -- npx -y macos-screencap-mcp@0.1.0

# Unregister
claude mcp remove screencap --scope user
```

### Claude Desktop

Add this to `~/Library/Application Support/Claude/claude_desktop_config.json`, then restart Claude Desktop:

```json
{
  "mcpServers": {
    "screencap": { "command": "npx", "args": ["-y", "macos-screencap-mcp"] }
  }
}
```

### Other MCP clients

Run `npx -y macos-screencap-mcp` as a stdio server. To skip npx, install the package globally with
`npm install -g macos-screencap-mcp` and use the command `macos-screencap-mcp`.

### Build from source

Requires Xcode or the Swift 6 toolchain.

```bash
git clone https://github.com/freeflow-im/macos-screencap-mcp.git
cd macos-screencap-mcp
swift build -c release
claude mcp add screencap --scope user -- "$PWD/.build/release/macos-screencap-mcp"
```

## Tools

| Tool | What it does |
|---|---|
| `list_displays` | Display ids, frames (global points), pixel scale |
| `list_windows` | App windows on every Space, on-screen ones frontmost first: `window_id`, app, title, frame, `on_screen`. Untitled off-screen windows are omitted. Optional `app` filter |
| `screenshot_region` | Capture `x, y, width, height` (global points), or a whole display if the rect is omitted, or `interactive: true` to let the user drag-select |
| `screenshot_window` | Capture one window by `window_id`, or by `app` / `title` substring (frontmost match). The window is captured even when other windows cover it or it is on another Space |
| `start_recording` | `target: "display"` (with optional `display_id`) or `target: "window"` (`window_id` / `app` / `title`). With `duration_seconds` the call blocks and returns the finished file. Without it, the call returns a `recording_id` |
| `stop_recording` | Finalize a recording. `recording_id` is optional when only one recording is active |
| `list_recordings` | Show the recordings that are in progress |

Screenshot tools save full-resolution PNG files, or JPEG when `output_path` ends in `.jpg`. They also return a
downscaled JPEG preview inline so the model can see the capture; pass `include_image: false` to skip it.
Captures are silent; pass `shutter_sound: true` to play the macOS screenshot sound.

Recordings are H.264 MP4 by default, or MOV when `output_path` ends in `.mov`. Above 4096 px they switch to
HEVC automatically. Recording options: `fps` (default 30), `show_cursor` (default true), `system_audio`,
`microphone`.

### Coordinates

All rectangles use macOS global display coordinates in points. The origin is the top-left of the main display,
and displays to the left or above it have negative coordinates. This is the same space that `list_displays` and
`list_windows` report, so you can pass a window's `frame` straight to `screenshot_region`. A rectangle is clipped
to the display that contains its center.

### File names and location

The capture tools take an optional `name`: a short description of the content, such as `teams-tab-my-trips`.
The tool descriptions ask agents to pass one. The server cleans up the name, adds a timestamp and picks the
folder:

```
teams-tab-my-trips_2026-10-28_16-30-02.png
```

When `name` is omitted, the server builds one from what it captured:

| Capture | Default name |
|---|---|
| Window (screenshot or recording) | `<App>_<window-title>_<timestamp>` |
| Region | The frontmost window under the region's center, as above |
| Whole display | `display-<id>_<timestamp>` |
| Interactive selection | `selection_<timestamp>` |

Names never overwrite an existing file. A collision within the same second gets a `-2`, `-3`, and so on.

Screenshots and recordings go to `~/Desktop`, the same place macOS saves its own captures. Set
`SCREENCAP_OUTPUT_DIR` to use another folder. `output_path` overrides all of this with an exact path.

If the server shuts down while recordings are still running (the client disconnects, SIGTERM, or SIGINT), it
finalizes them first so the files stay playable.

## Troubleshooting

- **The server doesn't connect** (`claude mcp list` shows it failing): check that you're on macOS 15 or later and
  that `npx -y macos-screencap-mcp` starts without errors in a terminal. If it starts, it waits silently for
  input; press Ctrl-C to exit.
- **"Could not read screen content"**: the app that launched the server lacks Screen Recording permission. Grant it
  under System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen that app.
  Permission belongs to the launching app (e.g. Terminal), not to this binary.
- **A window can't be found**: off-screen windows without a title are not listed. Call `list_windows` to see what
  is available; `on_screen: false` covers windows on other Spaces as well as hidden and minimized ones.
- **"ScreenCaptureKit/replayd did not respond within 15s"**: `replayd`, the per-user daemon behind
  ScreenCaptureKit, isn't answering. Screenshots fall back to `/usr/sbin/screencapture` and say so in a `fallback`
  field; listing tools return the error. `killall replayd` restarts the daemon (launchd respawns it). Set
  `SCREENCAP_SCK_TIMEOUT` (seconds) to change the wait.
- **Interactive capture returns "cancelled"**: the user pressed Esc, or no one was at the screen to make a
  selection.

## How it works

The server speaks MCP's newline-delimited JSON-RPC over stdin/stdout. All logging goes to stderr. Screenshots
use `SCScreenshotManager`. Recordings use an `SCStream` with an `SCRecordingOutput`, which writes the video file
directly. Interactive selection hands off to the system `screencapture -i` tool.

Listing and screenshot calls run in a short-lived copy of the binary (`macos-screencap-mcp --worker <tool>`), so
the long-lived server never opens a ScreenCaptureKit connection. Once a process has used ScreenCaptureKit, ReplayKit
keeps a connection to `replayd` until the process exits. If `replayd` stops answering a request, that client
reconnects every time the connection drops, hundreds of times a second, and the request can't be cancelled. A
worker that doesn't reply within `SCREENCAP_SCK_TIMEOUT` seconds (default 15) is killed, which ends its
connection. Recordings run in the server, with the same timeout on starting and stopping the stream.

| File | Contents |
|---|---|
| `Sources/macos-screencap-mcp/MCPServer.swift` | MCP protocol over stdio |
| `Sources/macos-screencap-mcp/Capture.swift` | Displays, windows, screenshots, file naming |
| `Sources/macos-screencap-mcp/Recording.swift` | Screen and window recording |
| `Sources/macos-screencap-mcp/Worker.swift` | Worker subprocess and the `screencapture` fallback |
| `Sources/macos-screencap-mcp/Timeout.swift` | Timeouts for ScreenCaptureKit calls and subprocesses |
| `Sources/macos-screencap-mcp/main.swift` | Tool definitions |
| `scripts/build-binary.sh` | Builds the universal binary for the npm package |

### Releasing

Bump `version` in `package.json` and `Sources/macos-screencap-mcp/Version.swift` (the build fails if they
differ), commit, then run `npm publish`. The `prepack` script builds the universal binary into `bin/`. npm can
take a minute or two to make a new version available.

## License

MIT. See [LICENSE](LICENSE).
