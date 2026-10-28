# Release performance probe for macOS

These tools archive a chosen committed revision into `.build/perf-harness-*`, add
auditable diagnostic hooks there, compile with `swift build --configuration release`,
and package the actual `ReadingBookApp` scene. The working product sources and the
installed application are not changed. No XCTest or `-enable-testing` is used.

All compiler scratch space, temporary files, libraries and raw measurements are
inside the repository. Source archive/hash, the complete instrumentation diff,
helper hashes, build arguments and binary hash are saved in `logs/<build-id>/`.
The only OS-created preferences/saved state collected are for the separate
`org.readingbook.perf-harness` bundle. Markdown web views already use the product's
nonpersistent data store.

```sh
python3 scripts/mac-performance/prepare.py --ref b164f6c --build-id perf-harness-20261028-release
python3 scripts/mac-performance/run.py --library-copy private-books/mac-release-20261028/library-before --rounds 1 --tag pilot-load
python3 scripts/mac-performance/run.py --library-copy private-books/mac-release-20261028/library-before --rounds 5 --tag load-wide
python3 scripts/mac-performance/run.py --mode import --pdf 'private-books/mac-release-20261028/library-before/books/A476E002-F6C8-4E7B-A072-C9236FB6EA2C/source/04_三国演义_繁体横排大字版_原文自排.pdf' --rounds 5 --tag import-wide
python3 scripts/mac-performance/run.py --mode warm --library-copy private-books/mac-release-20261028/library-before --rounds 1 --warm-repeats 6 --width 800 --height 600 --memory-offsets 30,60,120 --tag warm-narrow
```

Use `--manifest` for another prepared build. `prepare.py --resume --build-id ...`
rebuilds an existing diagnostic source copy after helper-only repairs and refreshes
the full source diff. Do not change copied sources while a build is running.

Each process receives its own copied library, or a new empty library for import.
Inputs must resolve inside the repository. The input library's hashes are checked
before and after. The application receives empty service profiles before AppStore
initialization, auto translation is off, and an empty model/disabled loopback URL
is used. The scenario never sends an AI query or starts analysis. It uses the real
PDF view, AppStore, workspace, companion projection and both mounted tabs.

The driver rejects concurrent ReadingBook and Swift compiler processes. Do not
use accessibility tools, screenshots or another workload during the measurement.
The log gate rejects either `being marked as needing layout` or `300 iterations`;
one line containing both counts as one warning. A log read failure also fails the
run rather than claiming zero warnings.
The probe activates its window once, and records active/key/occlusion visibility
at action readiness and memory checkpoints. A background/occluded run is retained
but marked ineligible, rather than silently combined with the foreground baseline.
Initial lifecycle states before the startup/import reader readiness boundary are
kept separately: a newly created window may not yet have received an occlusion
update. All subsequent reading actions and idle checkpoints are checked strictly.

The report boundaries have deliberately different meanings:

* External `mach_absolute_time` immediately before `open -n -W` is the normal
  LaunchServices request boundary. The per-process config is passed with `--env`.
  `proc_pid_rusage` supplies a separate process creation `ri_proc_start_abstime`
  boundary; `main.entry` is the actual launcher entry and excludes pre-main work.
  No accessibility lookup or tool response time is part of these clocks.
* Library load, import extraction, source copying, PDFDocument construction and
  PDF positioning have separate begin/end events.
* `reader.layout-ready` is emitted by the real PDF navigation settle callback.
  It is a native state/layout boundary, not a timestamp of presented pixels.
* Page operations call `navigateToUnit` for fixed pages 1, 8, 182, 800, 1484 and 182
  at 343% continuous vertical PDF settings. They measure programmatic page jumps,
  not scroll FPS, a hardware event, or the toolbar button's complete input path.
* Tab/close timings end after the expected store state and two main-queue echoes.
  This does not establish a window commit or composited frame latency.
* The first companion opening asserts that no projection receipt already occurred.
  Subsequent openings require a new receipt: fresh applied projection and verified
  product cache-hit receipts are reported separately. Existing cache behavior is
  preserved; caches are not forcibly invalidated to inflate warm timings.
* Memory offsets begin after the application reports reading preparation idle.
  The checkpoint records whether that state remains idle. App RSS and physical
  footprint come from `proc_pid_rusage`, with cumulative CPU counters and interval
  CPU percentages. Owned WebContent is attributed only through the probe's own
  WKWebView runtime getter and checked process-start identity. Inaccessible or
  unattributable WebContent is not added to app memory.

The initial archived probe used `userCPUTimeNanoseconds` and
`systemCPUTimeNanoseconds` as raw JSON field names for `ri_user_time` and
`ri_system_time`. Those integers are **Mach ticks**, as confirmed by Apple's
[XNU rusage implementation](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c)
and [task power accounting](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c).
The parser supports that original raw schema, normalizes it with the recorded
timebase, and emits `*CPUTimeMachTicks` plus cumulative CPU seconds. This is an
offline unit correction: raw events and the measured binary remain unchanged.
New probe builds use the correct raw field names.

Recheck the CPU units using the self-only offline calibration tool, outside every
benchmark interval. It compares Mach-converted `proc_pid_rusage` counters with
POSIX `process_time`, saves the result inside the repository, and exits nonzero
when the difference is at least 5%:

```sh
python3 scripts/mac-performance/calibrate-rusage.py --output logs/mac-performance/rusage-calibration.json
```

Five-run summaries report median and worst durations. Six cycles in one process
provide one unprewarmed cycle and five same-process warm cycles; page 182 arrival
and return are kept as separate occurrences in the aggregate. New process, fresh copied
library and fresh empty-library import do not mean a cold disk cache: hashing and
copying already read the PDF. These tools never purge system caches. Pixel first
screen latency, scrolling frame rate and GPU work remain unmeasured.

`--hold-final` leaves only the last measured process idle after `run.completed`
and writes its exact PID/executable to `held-process.json` for a subsequent visual
review. Stop it using `run.py --stop-held <workspace-local-held-process.json>`;
the driver verifies the executable and terminates only that owned process. The
10-second in-app heartbeat watchdog samples only its own PID before exiting.
The parser truncates all timing/resource analysis at the first `run.completed`
timestamp, so a held app's later screenshots and interactions cannot contaminate
the saved results. `--profile-startup --hold-final` adds a separate five-second
sample of the verified actual app PID; the run is marked `profiled` and must be
excluded from every baseline aggregate.
