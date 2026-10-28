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
