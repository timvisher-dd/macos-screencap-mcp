# Capture design

ScreenCaptureKit is the supported way to list and capture windows, but every call goes through `replayd`, a
per-user daemon, and `replayd` can stop answering. When it does, an `await` never returns and can't be cancelled.
This note sets out the rules the capture path follows so that a stuck `replayd` costs one call a bounded wait,
not a hung agent. It follows the approach of AltTab's
[`WindowCaptureEventsSpecs.md`](https://github.com/lwouis/alt-tab-macos/blob/master/src/events/WindowCaptureEventsSpecs.md),
which treats ScreenCaptureKit as unreliable and designs around it.

## Rules

1. **No ScreenCaptureKit in the server.** Listing and screenshot calls run in a short-lived worker process
   (`--worker <tool>`). Once a process has used ScreenCaptureKit, ReplayKit keeps a connection to `replayd` until
   the process exits. If a request on it stalls, the client reconnects hundreds of times a second for as long as
   it lives. A worker is SIGKILLed after `SCREENCAP_SCK_TIMEOUT` (15 s), which ends its connection.
2. **Screenshots use `captureScreenshot` on macOS 26.** `captureImage` and `captureSampleBuffer` set up and tear
   down an `SCStream` for every call (10 `SCStream` allocations for 10 `captureImage` calls; none for
   `captureScreenshot`). AltTab saw that path leak WindowServer memory (#5786). macOS 15 keeps `captureImage`.
3. **One discovery request in flight.** `SCShareableContent` requests are single-flight: callers that arrive while
   one is pending share its result. A request whose callback hasn't arrived after `SCREENCAP_DISCOVERY_TIMEOUT`
   (5 s) is expired. Its waiters get a timeout, the next caller starts fresh, and a late callback is ignored.
4. **One capture at a time, machine-wide.** Each agent session starts its own server, so there can be dozens. Every
   listing or screenshot call holds one of `SCREENCAP_MAX_CAPTURES` slots (default 1) across its worker and any
   fallback. A slot is a file under `~/.local/state/macos-screencap-mcp` locked with `flock(2)`, so the kernel
   frees it when the holder dies, even on SIGKILL. A call that waits longer than `SCREENCAP_SLOT_WAIT` (30 s)
   fails rather than queueing forever. The default is 1, not AltTab's 2: two workers in separate processes starting
   at once made `replayd` stall discovery and fail TCC checks, where the same four calls one at a time all
   succeeded within 2 s.
5. **Fall back away from `replayd`.** When a window screenshot times out, the server tries SkyLight's private
   `CGSHWCaptureWindowList` (looked up with `dlsym`, run in its own worker with a 15 s timeout), which reads the
   window from WindowServer without `replayd`. Then it tries `/usr/sbin/screencapture -l`. Region screenshots go
   straight to `screencapture -R`. The result's `fallback` field says which method answered and why.
6. **Tell the caller to stop.** Every timeout message ends with "Stop and tell the user rather than retrying",
   because retrying against a stuck `replayd` adds load and never helps.

Recordings still run in the server, with the 15 s timeout on starting and stopping the stream, and don't take a
capture slot, because a recording holds its stream for minutes.

## What we've seen

Measured on macOS 26.7.2 in November 2026, with about 45 servers running and two of them stuck in the reconnect
storm from rule 1 (old builds, from before workers):

- The storm alone keeps `replayd` at 60-85% CPU.
- `replayd` stalls requests per exact executable path. Every capture from `~/.local/bin/macos-screencap-mcp`, the
  stuck clients' path, stalled until the 15 s timeout, whichever build was installed there. The same binary run
  from any other path, including a sibling file in `~/.local/bin`, answered in about 1 s. Restarting `replayd`, or
  ending the stuck clients, should clear this.
- With the binary location held constant, `captureImage` and `captureScreenshot` were equally fast, and `replayd`'s
  CPU didn't measurably differ. The storm's load hides any per-capture difference.
- A capture stalled this way adds 7-8 s of `replayd` CPU over its 15 s timeout, with either API.

## Next

The cap in rule 4 is a stopgap. The real fix is one shared capture daemon for the machine instead of one server
per session: one ScreenCaptureKit client, its own queue, and no per-session processes to get stuck.
