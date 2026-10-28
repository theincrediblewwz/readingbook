# Native companion-menu layout regression

Run from the repository root on macOS with an AppKit/SwiftUI SDK:

```sh
python3 scripts/ui-layout-regression/run.py
```

This compiles the actual `ReadingAdaptiveRows`, `ReadingControlRowsGeometry`, `ReadingGlass`, and `FrostWindowAppearance` sources. A synthetic reader panel exercises widths 240–760 pt, opening/closing and collapse animations, hidden chat, and disabled-state changes. The inactive chat and its original `ViewThatFits` layouts, including the suggested-question buttons, remain mounted. No library, credentials, book, or AI provider is accessed.

The two normal cases (glass and opaque) must complete 100 timer ticks, avoid SwiftUI publication and AppKit 300-iteration warnings, and keep menu-background native marker construction bounded. A marker measures the lifecycle of the menu's view subtree; it does not swizzle or count AppKit's private popup initializer.

All binaries, module caches, and temporary files are under `.build/ui-layout-regression/`. Build, resource metrics, process samples, system logs, source hashes, and `result.json` are under `logs/ui-layout-regression/`. A watchdog samples and terminates only the test process it started if progress stalls. Test windows are offscreen by default; `--visible` shows only the synthetic window.

To explicitly reproduce the previous structure on affected macOS versions:

```sh
python3 scripts/ui-layout-regression/run.py --baseline
```

Baseline mode intentionally restores only the companion toolbar's old `ViewThatFits` alternatives. It succeeds only if the timer stalls before tick 100 and the watchdog observes at least 256 menu-background native marker constructions. This manual negative control is not part of normal CI; a macOS version without the framework defect may not reproduce it. The real 26.5.2 incident and the isolated baseline both produced the same 300-iteration layout warning and `NSHostingView.layout → sizeThatFits` stacks.

On the original probe, the baseline stalled at tick 40 and constructed more than 5,000 markers. Replacing only the companion toolbar kept chat unchanged and completed 100 ticks with 24 constructions. The regression verifies that targeted difference rather than rewriting unrelated chat controls.
