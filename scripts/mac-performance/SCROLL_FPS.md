# Captured PDF content-update cadence on macOS

This standalone diagnostic uses ScreenCaptureKit to capture **one explicitly
selected ReadingBook window**, owned by a verified workspace-local executable and
PID/start identity. It captures no desktop, other application, cursor, microphone
or audio. It does not inject input. Use Cua for physical-input tests, or separately
label a diagnostic app's own programmatic scroll input.

It measures **captured PDF ROI content-update FPS**, not hardware scan-out, GPU
presentation FPS, a display-link callback count, or input-to-pixel latency.
ScreenCaptureKit `.complete` frames supply WindowServer `displayTime` Mach ticks.
A complete frame counts as a PDF update only when the sampled PDF pixels change.
The ROI must exclude animated status indicators, toolbars, floating panels, hover
cards and the cursor; otherwise a breathing dot can falsely look like smooth PDF
scrolling. Capture ceiling, low-texture pages and observer cost can understate
updates. Record those limits rather than calling all low rates application drops.

Primary references: Apple's [capture sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos),
[frame metadata](https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo),
and [displayTime](https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo/displaytime).
The installed Apple SDK `ScreenCaptureKit.framework/Headers/SCStream.h` specifies
that displayTime uses mach absolute time, and `.idle` means no new frame was
generated because the display did not change.

## Build and permission preflight

Keep the binary, temporary files and compiler caches inside the workspace:

```sh
mkdir -p .build/scroll-frame-capture/module-cache .build/scroll-frame-capture/tmp
TMPDIR="$PWD/.build/scroll-frame-capture/tmp" \
CLANG_MODULE_CACHE_PATH="$PWD/.build/scroll-frame-capture/module-cache" \
swiftc -O -swift-version 5 -parse-as-library \
  -module-cache-path "$PWD/.build/scroll-frame-capture/module-cache" \
  scripts/mac-performance/ScrollFrameCapture.swift \
  -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo \
  -framework CoreGraphics -framework AppKit -framework ImageIO \
  -framework UniformTypeIdentifiers -lproc \
  -o .build/scroll-frame-capture/ScrollFrameCapture

.build/scroll-frame-capture/ScrollFrameCapture \
  --workspace "$PWD" --output "$PWD/logs/scroll-fps/preflight-unique" \
  --preflight-only
```

The preflight calls **only** `CGPreflightScreenCaptureAccess`, never requests or
changes permissions. Missing access writes `blocked-screen-capture-permission`
and exits77 without asking for access, enumerating windows or starting capture.
Ask the user to grant permission manually only if necessary. Existing permission
does not cause any permission expansion. Each output directory must be new.

## Capture one owned window

Set the PID, executable and bundle from the held isolated test process. The path
must resolve inside this repository; PID/start identity is checked before stream
creation. An ambiguous set of owned windows requires `--window-id`.

```sh
.build/scroll-frame-capture/ScrollFrameCapture \
  --workspace "$PWD" --output "$PWD/logs/scroll-fps/reading-wide-unique" \
  --pid OWNED_PID \
  --expected-executable "$PWD/.build/OWN_BUILD/OWN_APP.app/Contents/MacOS/ReadingBook" \
  --bundle org.readingbook.perf-harness \
  --roi 180,130,650,450 --scale 1 --max-fps 120 --seconds 20
```

`--roi x,y,width,height` uses **output-buffer pixels**, top-left origin. The example
ROI is illustrative and must be chosen from the actual test window. Output width
and height are window points multiplied by `--scale` (default1). A Retina Cua
screenshot may be twice those dimensions. Output excludes window shadows and child
windows. Do not resize or move overlay panels during the timed interval.

Use optional `--preview` in a **separate** short setup capture to save a PNG of only
the owned window and verify ROI placement. Default capture persists no image or
video, just timestamps, status, ROI change/darkness fractions, a non-reversible
sample signature and processing time. The preview's first-frame conversion adds
cost; do not mix that setup capture into a benchmark.

The default ROI grid samples every3 pixels, counts a pixel as changed when any RGB
channel changes by more than3, and counts a new content update when at least0.1%
of the grid changes. Configure these with `--pixel-step`, `--channel-delta`, and
`--changed-fraction` only before comparative runs, and keep them identical. Low
texture is a limitation: scrolling a blank white margin can show no pixel change.

`capture-started` JSON is printed immediately after startCapture. It includes the
common-clock captureStartMachTicks, selected window ID, dimensions and ROI. The
collector samples only whether the target is frontmost every250ms; no unrelated
application metadata is persisted. It exits after a bounded1–120 seconds and
never activates or controls the target application.

## Mark and analyze actual scrolling

Capture some idle/setup margin before and after the independently marked scroll
interval. A native diagnostic app can emit its own `mach_absolute_time()` start/end
markers; an operator may specify recorded relative times, labelled as such. Do
not infer input duration from the first/last changed pixel, trim silent gaps, or
report whole-capture FPS as scrolling FPS.

```sh
python3 scripts/mac-performance/analyze-scroll-capture.py \
  --capture logs/scroll-fps/reading-wide-unique \
  --start-ticks ACTUAL_SCROLL_START --end-ticks ACTUAL_SCROLL_END \
  --label programmatic-continuous-scroll \
  --roi-confirmed --continuous-input \
  --output logs/scroll-fps/reading-wide-report.json
```

Alternatively use `--start-seconds 3 --end-seconds 15` relative to capture start,
or `--intervals-file` with a JSON list (or `intervals` object key) of
`label`, `inputMethod`, `startMachTicks`, `endMachTicks`. Explicit interval bounds
are mandatory and must lie wholly inside the capture. The confirmation flags are
assertions by the test operator, not automatic proof: omit them when ROI/input
evidence is missing. A series of isolated scroll calls with pauses is not
continuous input; label it as an operator window rather than asserting continuity.

The report keeps the full interval as denominator, including gaps. It reports
changed-frame FPS, complete-capture FPS, duplicate/below-threshold frames, median/
p95/p99/max change intervals and silence including interval boundaries. It rejects
uncovered/background intervals or missing capture clocks for qualification. It
also records ROI processing time and collector CPU over the whole capture; extra
WindowServer/GPU capture cost is not included in that process CPU figure.

Run analyzer semantics checks without UI or capture:

```sh
PYTHONPYCACHEPREFIX="$PWD/.build/scroll-frame-capture/python-cache" \
python3 scripts/mac-performance/test-scroll-capture-analysis.py
```

## Repeatable own-process continuous scroll input

`ScrollDrive.m` is a small diagnostic dylib. It changes no application binary or
book file. The exact same driver can be loaded into the frozen baseline and a new
workspace-built, ad-hoc-signed ReadingBook app. It does not post system events,
call AppleScript, activate any window, or force drawing/layout. It directly calls
the selected app's own PDF `NSClipView.scrollToPoint` and
`NSScrollView.reflectScrolledClipView` on its main queue. This is **programmatic
continuous input**, not a trackpad gesture or hardware-input latency test.

```sh
TMPDIR="$PWD/.build/scroll-frame-capture/tmp" \
CLANG_MODULE_CACHE_PATH="$PWD/.build/scroll-frame-capture/module-cache" \
xcrun clang -dynamiclib -fobjc-arc -O2 -mmacosx-version-min=15.0 \
  -fmodules -fmodules-cache-path="$PWD/.build/scroll-frame-capture/module-cache" \
  -Wall -Wextra -Werror scripts/mac-performance/ScrollDrive.m \
  -framework Foundation -framework AppKit -framework PDFKit \
  -o .build/scroll-frame-capture/libReadingBookScrollDrive.dylib
```

Before launching, create a fresh control directory inside this repository and a
UUID nonce. Pass these environment variables **explicitly to the target app**
with LaunchServices `open --env NAME=value`, in addition to that test app's usual
isolated-library configuration:

| Variable | Required value |
|---|---|
| `DYLD_INSERT_LIBRARIES` | Absolute workspace path to `libReadingBookScrollDrive.dylib` |
| `READINGBOOK_SCROLL_WORKSPACE` | Canonical repository root |
| `READINGBOOK_SCROLL_EXPECTED_EXECUTABLE` | Exact canonical test app executable path, inside the workspace |
| `READINGBOOK_SCROLL_CONTROL` | Fresh existing workspace control directory |
| `READINGBOOK_SCROLL_NONCE` | That run's UUID nonce |

Do not put `DYLD_INSERT_LIBRARIES` on `/usr/bin/open` itself or another process.
Do not weaken code-signing/system protections if a host refuses loading; report
the limitation and use an explicitly instrumented diagnostic app instead.
Do not reuse an old PerfProbe output directory/config: its event output may be
recreated. Use a fresh copied library/output and hold the test app open.

The constructor first checks its actual executable against the exact configured
workspace path. A WebKit/other child host therefore does nothing. It then waits
for a visible own PDFView whose **PDF document URL also resolves inside the
workspace**. It requires a scrollable clip and stable bounds over several polls.
It never operates a real-library PDF accidentally inherited from preferences.

Once `driver-ready.json` exists, use its `windowID` for the independent capture
tool. Bring the test window forward using Cua, close overlays, inspect the ROI,
then start a fresh capture with setup/idle margins. Atomically write `start.json`
in the control directory, for example:

```json
{
  "nonce": "THE-SAME-RUN-UUID",
  "durationSeconds": 12,
  "pointsPerSecond": 600,
  "inputHz": 60,
  "direction": "down",
  "startAfterSeconds": 2
}
```

Input uses elapsed Mach time rather than adding a fixed delta per timer callback;
a blocked main thread catches up on its next coalescing timer delivery. The driver
logs each requested/actual clip position, common Mach timestamp, current page and
foreground state. It aborts as ineligible if the target loses foreground, PDF/clip
ownership changes or document bounds clamp the requested scroll. Choose a middle
page with sufficient distance for the full requested motion. Requested60Hz input
also limits the update rate the experiment can demand; actual delivery cadence is
visible in the trace and must not be confused with display refresh capability.

The command yields `scroll-start.json`, `scroll-trace.json` and
`scroll-intervals.json`. Tick data remains in memory during scrolling and is written
after the final command. Require trace `status=completed`, all foreground states
true, actual clip displacement and page-boundary crossing before treating the
interval as qualified continuous input. The startup marker's small file write is
part of diagnostic overhead; use the same driver and settings for comparisons.
The tool never kills the app. A separate deadline only writes a watchdog record if
the main queue has not finished.

Feed `scroll-intervals.json` to the analyzer's `--intervals-file`, together with an
independent ScreenCaptureKit capture of that window. The driver timer count is
**input evidence only**; measured FPS still comes from changed PDF pixels and
WindowServer display timestamps. No frame rate may be claimed from driver ticks.

## One-run orchestration

`capture-scroll-run.py` avoids a stale driver while a human inspects setup. It
creates a fresh held run through `run.py --scroll-driver`, verifies the frozen
binary and input library hashes, waits for that run's nonce/driver/window, starts
the independent collector, then immediately writes a two-second-delayed scroll
command. At343% zoom its default **200 PDF document/clip-coordinate points/s** is
approximately686 screen points/s. The command above using600 document points/s
would be approximately2058 screen points/s; these speed units must not be mixed.

```sh
PYTHONPYCACHEPREFIX="$PWD/.build/scroll-frame-capture/python-cache" \
python3 scripts/mac-performance/capture-scroll-run.py \
  --manifest .build/perf-harness-20261028-release/build-manifest.json \
  --fixture private-books/mac-refinement-20261028/library-before \
  --tag UNIQUE-baseline-wide-scroll --roi 500,160,750,450 --pixel-step 6 \
  --roi-confirmed
```

The illustrated wide ROI was inspected for a1470×843 window. A narrow window or
different panel layout requires a new own-window preview and explicit ROI choice.
Do not silently reuse it. Each comparative run must use the same driver/collector,
ROI, threshold, grid, zoom, speed and requested input cadence.

The collector optionally waits for the target to become frontmost **after** its
nonactivating AppKit initialization and **before** starting the capture clock.
If the wrapper prints `needs-cua-activation`, the input command has not been
written; use Cua to activate the already held isolated app. The collector waits
up to60 seconds without changing focus itself. If it times out, the fresh control
remains unconsumed and the held process is retained for inspection, not hiddenly
killed or replaced.

For qualification, the wrapper requires completed input, foreground evidence,
actual clip displacement and a page-boundary crossing established by native
`visiblePages`/center `pageForPoint` before and after input. `PDFView.currentPage`
can stay cached under direct clip input and is retained separately; it is not
used as crossing proof. Those geometry queries are outside the timed input window.
The wrapper also requires the capture analyzer and warning-log gates, then stops
only its exact held executable/PID and verifies input/binary hashes. All failures
are kept locally and excluded. A successful pilot is one sample, not a multi-run
benchmark or a hardware-gesture frame-rate claim.

## Freeze, diagnostic provenance and comparison

Before the final Release build, verify the literal hook preimages against the
**raw product source tree**, without compiling or launching anything:

```sh
PYTHONPYCACHEPREFIX="$PWD/.build/scroll-frame-capture/python-cache" \
python3 scripts/mac-performance/verify-performance-hooks.py \
  --output-prefix logs/mac-performance/final-source-hook-check
```

The checker replays `prepare.py`'s hook literals in memory, including the legacy
empty AppStore initializer or the sharedAIRequests-injected initializer selector.
It requires each preimage once and confirms both fresh/cached companion receipts.
It rejects already instrumented trees. It is a compatibility check, not proof of
Swift compilation or UI behavior; archive and build the final committed source
only after product/UI work is frozen.

`run.py` now carries `scrollDiagnostic`, `latencyBaselineExcluded` and explicit
exclusion reasons on **each result and the summary**, as well as launch metadata.
Injected-scroll and startup-sampled runs retain diagnostic timing aggregates but
must not enter ordinary startup/action latency comparisons. Normal unprofiled
runs report `scrollDiagnostic=null` and `latencyBaselineExcluded=false`. The scroll
pixel measurement remains a valid separate data line when its own gates pass.
Existing historical artifacts are not rewritten to add these fields.

Aggregate exactly three distinct wide plus three distinct narrow qualified cases:

```sh
PYTHONPYCACHEPREFIX="$PWD/.build/scroll-frame-capture/python-cache" \
python3 scripts/mac-performance/summarize-scroll-matrix.py \
  --wide NEW-wide1,NEW-wide2,NEW-wide3 \
  --narrow NEW-narrow1,NEW-narrow2,NEW-narrow3 \
  --output-prefix logs/mac-performance/new-release-scroll-matrix
```

It reads the actual app version/build from that frozen bundle rather than assuming
the old baseline's version. It enforces matching tool/binary/input hashes within
the matrix, actual window sizes and configured ROI/threshold/input conditions.
The old saved baseline matrix is not refreshed or remeasured.

Compare two existing matrices only after the new source has been frozen and its
six cases actually qualify:

```sh
PYTHONPYCACHEPREFIX="$PWD/.build/scroll-frame-capture/python-cache" \
python3 scripts/mac-performance/compare-scroll-matrices.py \
  --before logs/mac-refinement-20261028/scroll-fps/baseline-scroll-matrix.json \
  --after logs/mac-performance/new-release-scroll-matrix.json \
  --before-label 0.23.9 --after-label NEW_VERSION \
  --output-prefix logs/mac-performance/scroll-before-after
```

Different driver/collector or fixture hashes, ROI, input, capture settings or
qualification block comparison. Outputs are descriptive per-window deltas, pooled
gap percentiles and observer CPU; small sequential three-run differences are not
automatically declared wins. Metadata/condition tests do not launch an app:

```sh
PYTHONPYCACHEPREFIX="$PWD/.build/scroll-frame-capture/python-cache" \
python3 scripts/mac-performance/test-performance-tool-contracts.py
```
