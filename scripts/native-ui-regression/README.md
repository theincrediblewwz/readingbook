# Native UI regression

`build.py` links the actual testable Debug product objects, excluding only the normal launcher. `run.py` creates a separate native application and workspace-local library copy. It never controls the installed app, reads a provider key, or starts an AI request. XCTest is not required.

```sh
python3 scripts/native-ui-regression/build.py --bin-dir .build/tests/debug
python3 scripts/native-ui-regression/run.py --mode workspace --cycles 24 --tag ci-workspace
```

Without `--bin-dir`, the builder performs a Debug build under `.build/native-ui-harness/product`. `--mode panel` hosts the real companion/floating panel directly. The default fixture contains 1,484 synthetic source units, not a physical PDF. Optional `--library-copy` accepts only a workspace directory and copies it again before loading it.

## Timing attribution and budgets

The timer queues a main-thread heartbeat every 50 ms. A pulse captures its phase and action when queued, before its waiting interval. A startup pulse delayed across the scenario boundary retains its queued-phase label and full lag. Its waiting-interval overlap after the first-open boundary also counts toward the interactive maximum, so a boundary-straddling first-open stall cannot lose the first 0–50 ms. Samples include delivered phase and overlap for audit. Actions are labelled before the state/window mutation, including synchronous resize work.

- `starting` includes AppStore, content, NSHostingView/window initialization and the existing 500 ms settle interval.
- `scenario` begins immediately before the very first companion open. There is no pre-open or additional warm-up.
- `settling` is the existing final 500 ms after the last close and uses the interactive budget.

The global peak is never cleared. Results retain startup and interactive peaks, per-phase peaks, the worst pulse, and the worst 100 pulses above 0.5 seconds with an uncapped count. The hard five-second watchdog applies in every phase: it samples the test child and fails. Interactive lag, including the first open, must stay below 1.5 seconds. Startup has a separate five-second budget. These are responsiveness gates, not FPS measurements; timer resolution is 50 ms.

Passing also requires all actions to finish, preserved draft, no query/analysis running, visible native window and layout/heartbeat activity, readable same-PID logs, and zero `300 iterations` / publishing-during-view-update warnings. Failures return nonzero.

The first CI attempt `40635956572` remains a failed run: all 144 actions finished with no runtime warnings, but its undifferentiated global peak was 1.7156 seconds against the old global 1.5-second gate. It did not record enough attribution to establish whether the peak was initialization or an interaction. The phase-aware harness adds evidence and keeps the interactive gate unchanged; it does not retroactively convert that failure into a pass.

This checks programmatic state transitions and native layout. Physical-PDF cold import, pointer/selection/annotation QA, the full Core suite and installed Release validation remain separate checks.

## Physical PDF correctness mode

Reuse the same completed Debug build and runner; `--mode pdf` creates an eight-page
PDF and user note in its isolated workspace library, rather than loading a real
book. It hosts the actual `ReaderWorkspaceView` and inspects public PDFKit objects:

```sh
python3 scripts/native-ui-regression/build.py --bin-dir .build/mac-debug/arm64-apple-macosx/debug
python3 scripts/native-ui-regression/run.py --mode pdf --cycles 3 --tag pdf-lazy-thumbnails
```

The source URL is deliberately withheld for 350 ms while every sampled native
hierarchy must contain neither a temporary extracted-text `WKWebView` nor a stale
PDF container. Once the URL arrives, the real `PDFThumbnailView.pdfView` must be
nil while closed, bind to the actual PDF view when opened, navigate through a
native collection-item click, and unbind on close. The click uses public AppKit
events queued only to this test application's own window; no AppleScript,
accessibility automation, global event injection or private PDFKit API is used.
Each requested cycle closes, reopens and navigates the real reader.

Additional assertions cover same-URL updates, same-URL workspace-memory revisions
that show/hide thumbnails, and complete same-book reader teardown/reload with
saved page, fit mode, direction, continuous mode and visible/hidden thumbnail
preferences. Original PDF and Markdown bytes must remain identical. Cached PNGs
and per-assertion `result.json` stay in the run's `logs` directory. Native GPU
layers may be absent from `NSView.cacheDisplay` PNGs; these are diagnostic caches,
not visual pass evidence. Native object/action and persisted-file assertions are
the correctness evidence. The existing
five-second watchdog, process-scoped runtime-warning scan and manifest checks
still apply. This is correctness coverage, not a scroll-FPS benchmark, cold-import
test, or full annotation/search test. `--library-copy` is intentionally rejected
for this fixture-only mode. Run it separately from any performance capture or
interactive UI session.

## Offline AppStore AI concurrency

`AIConcurrencyProbe.swift` runs the real AppStore, independent production AIReaders,
shared coordinator, progress mailboxes and canonical repository commits. An injected
in-memory transport holds a companion response while a real chat request completes,
then checks lane-specific cancellation, a replacement run's identity, preserved
concurrent results/Markdown/source bytes, and same-instance library-load recovery.
It also verifies that cancelling existing-plan regeneration or confirming a plan
that changed in the meantime sends no request and never starts a reading task.
Delayed failed/cancelled replanning must preserve the confirmed plan, session,
views and user Markdown both in memory and on disk. A separate injected short
connection probe checks that editing settings while a test waits clears only
its own pending status and never presents the old result as a new connection.
The fixture deliberately has an AI plan recommending one background worker; that
recommendation must not override the host's default two independent request slots.
No network request, installed app or real key is used. This is a correctness probe,
not a performance measurement, and it does not create a window.

First finish the Debug product build, outside any performance interval. Then:

```sh
python3 scripts/native-ui-regression/build-ai-concurrency.py --bin-dir .build/tests/debug
TMPDIR="$PWD/.build/ai-concurrency-probe/tmp" .build/ai-concurrency-probe/ai-concurrency-probe "$PWD" "$PWD/logs/ai-concurrency-unique-run"
```

The output directory must be new and inside the workspace. The probe writes its
fixture library and `result.json` there; source/object/binary provenance is in
`.build/ai-concurrency-probe/build-manifest.json`. The linker reuses the completed
product objects and never initiates a concurrent product build. A failed assertion
exits nonzero. Test-only UserDefaults are removed on exit; user preferences are
never read from the installed application's domain.

## Interactive offline AI workspace

`AIConcurrencyUIHost.swift` opens the actual `WorkspaceView` in a separate native
app (`org.readingbook.ui-concurrency-test`). It creates one synthetic source unit
with two paragraphs, valid fixture receipts, three saved explanations and a user
Markdown note. Its injected transport holds companion requests in memory while a
chat request can run `source_read(u1)` and finish. The connection-test callback is
also injected. No HTTP request or real credential is used by these test paths.
The window is deliberately labelled “离线测试”. This is UI correctness coverage,
not an FPS fixture. Build only after the main Debug build and performance capture
have finished:

```sh
python3 scripts/native-ui-regression/build-ai-concurrency-ui.py --workspace "$PWD" --bin-dir .build/tests/debug
".build/ai-concurrency-ui/ReadingBook Offline Concurrency.app/Contents/MacOS/ReadingBookOfflineConcurrency" --workspace "$PWD" --output "$PWD/logs/ai-concurrency-ui-unique-run"
```

The builder only links completed product objects and packages their own resource
bundle inside `.build`; it does not start the product build or launch a window.
The host requires a new, workspace-local `--output` directory and the exact test
bundle identity. Optional window arguments are `--width 800 --height 632`.
Library, source, note, controls, temporary home, temporary files and JSON evidence
stay under that run directory. Empty volatile service profiles prevent credential
loading, and the test preference domain is removed on termination.

Use real pointer actions to inspect the latest expanded explanation, collapsed
newest-first history, single-row toolbar, tooltips and regeneration confirmation.
Cancelling confirmation must leave `state.json`'s `companionRequests` at zero.
Continue generation to reach the visible waiting phase, switch to “对话” and send
the prefilled question, then open model settings while the companion is waiting.
`state.json` records exact run IDs, request counts, lane admission gates and the
persistent `chatCompletedWhileCompanionHeld` observation. `ready.json` identifies
the process and fixture. Control files under that run directory are consumed:

- `control/release-companion`: complete the held in-memory model response.
- `control/hold-companion`: hold subsequent companion requests again.
- `control/long-next-companion`: arm one long Markdown reply for the next
  companion request. Its formula blocks, inline math, table, local source link
  and ending marker exercise full-content preview/expand/copy/note actions. Two
  valid anchors reference the fixture's exact `u1` sentences, “刘备在此。” and
  “关羽随后而来。”, so the multi-source selector has two genuine choices. The
  control file is consumed and the flag clears when that next request starts;
  arming while a previous request waits does not change the older response.
- `control/checkpoint-draft`: write the actual current editor title and complete
  Markdown to this run's private `draft-checkpoint.json`, with UTF-8 byte count,
  SHA-256, dirty flag, selected document and route. It never saves the draft into
  the fixture library or changes the editor.
- `control/quit`: cancel remaining fixture tasks, verify original source, saved
  explanations and Markdown preservation, preserve the current editor draft in
  `draft-checkpoint.json`, write `result.json`, and exit. Normal window/app
  termination also preserves the current draft checkpoint.

`state.json` additionally records whether the one-shot long reply remains armed,
the last prepared original reply's SHA-256/UTF-8 size/layer ID, returned-long-reply
count, actual draft title/size/hash/dirty state/document/route, and the current
question's send admission. `long-companion-original.md` retains the original
synthetic Markdown for exact copy/save comparisons; `longCompanionReplies` stays
zero if the prepared long reply was cancelled before returning. The initial
short answer and three original history records are unchanged. None of these
controls reads a real key, calls a network service, or automatically saves notes.

Closing the window also terminates the app; use `control/quit` when a final
assertion report is needed. An unfinished UI scenario is reported as `incomplete`.
Source/object/binary hashes are recorded in the builder's `build-manifest.json`.
