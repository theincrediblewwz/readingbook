# Native Markdown bridge regression

Links an already completed testable Debug product and hosts its actual
`RichMarkdownView`, bundled renderer and WKWebView. All books/images are synthetic
fixtures under the requested workspace output. No AppStore, provider key, real
library, installed app, network request or general clipboard is used.

Run after the coordinated product build and outside performance measurements or
other interactive UI tests:

```sh
python3 scripts/mac-markdown/run-native-probe.py \
  --workspace "$PWD" \
  --build-dir .build/tests/debug \
  --output-dir logs/ci-markdown-bridge/native-probe \
  --run --show-window
```

The wrapper never initiates a product build. Without `--run`, it links only.
`--show-window` starts a regular owned application, activates its key window, and
requires foreground before testing the real RAF → size → SwiftUI → native height
loop. The diagnostic uses a normal application delegate and `NSApplication.run`.
An inactive/unshown mode can throttle RAF and is not a substitute for this gate.
No global keyboard/pointer events or screenshots are synthesized.

The private MarkdownWebView, coordinator and state stay private. An observable
model drives the real SwiftUI representable path; the test finds the actual web
view recursively. Test-only JS observes actual DOM references, selected ranges
and renderer calls, forwarding the original functions. The actual native menu
item comes from `willOpenMenu`; `NSApp.sendAction` exercises its real target.
This instrumentation is for correctness, not performance numbers.

Required checks cover nonempty math/table/code/mark/image controls, exact Unicode
and UTF-16 source selection, semantic math selection, complete source in saved
native actions, style DOM/range preservation, deferred decoration changes,
real focus and clear-focus, source links, old action/message rejection, distinct
Markdown/source/mode/directory replacements, revoked/unsupported images, rapid
mixed updates, teardown and original synthetic source preservation. The real
focus-clear regression first focuses a mark, allows its native completion to
settle, sets the model focus to nil, then verifies zero `.source-focused` nodes
after 500 ms. It never calls JS to clear focus on the test's behalf.

Each output name must be new. Frozen source/helper/object/binary hashes, compiler
and runtime logs are independent adjacent sidecars; failures are never replaced.
Compiler warnings, layout/publishing/AttributeGraph warnings, missing checks,
timeout or any false assertion make the wrapper fail. A child timeout remains a
failed run. Binary/tmp/CF home stay in `.build/native-markdown-bridge-probe`, and
Swift/Clang caches are shared `.build/shared-module-cache/{swift,clang}`.

CI should add the command as one sequential step after native note-editor checks
and before packaging, using the existing `.build/tests/debug` objects. Do not
parallelize this foreground window with other native UI or performance work.
The owner integrates the workflow and cleanup policy separately.

## Input-byte identity regression

Run this additional sequential command with the same completed Debug objects:

    python3 scripts/mac-markdown/run-input-identity-probe.py \
      --workspace "$PWD" \
      --build-dir .build/tests/debug \
      --output-dir logs/ci-markdown-bridge/input-identity \
      --run --show-window

This thin entry point shares the linker/provenance/warning/timeout logic above.
Its helper and CF home use .build/native-markdown-input-probe and the shared
compiler caches. It runs 24 real RichMarkdownView cases: initializer or legal
sourceText setter, stored-once callbacks or all callbacks nil, Markdown-only or
sourceText-only change, and ASCII/NFC-NFD/equal-byte-length combining-mark reorder.
All cases also change theme, verify that the host body ran, and inspect actual
full-render arguments for exact UTF-8. Eight ASCII controls distinguish a broken
observer/entry from the 16 canonical-equivalence cases. Each case uses a fresh
host, but input changes never force a new .id or recreate the web view to pass.

The baseline failed all 16 canonical cases despite the host body rerunning;
the same 24 cases/152 expectations pass after preserving custom UTF-8 identity
at both SwiftUI input boundaries, including the sourceText setter. The ordinary
29-case bridge regression must also continue to pass. Its Unicode check alone
could be masked by fresh model-capturing callback contexts and does not replace
the stable/nil callback input regression.

Limits: this does not emulate hardware drag/shortcut delivery, bypass CSP to
forge frame metadata, exhaust all malformed/oversized payloads, hold an image
read-in-flight race, test 5,000 progressive marks, measure FPS or establish an
optimization benefit. In the initial baseline, the positive mark stayed focused
after the model cleared it; adding the missing native JS return made the same
29 expectations pass. Detailed failed and passing evidence remains in this work
cycle's `logs/webkit-bridge-20261029/regression`.


## Saved-history reference regression

Run sequentially in the allocated foreground interval with completed Debug
objects (the wrapper starts no product build):

    python3 scripts/mac-markdown/run-history-reference-probe.py \
      --workspace "$PWD" --build-dir .build/tests/debug \
      --output-dir logs/ci-markdown-bridge/history-reference --run --show-window

The actual EnhancedBookChatView receives AppStore.openInternalURL(book/message)
and opens the production sheet. Six cases cover 60 messages at 0/58/59 and 1000
at 0/500/998. Guards compare complete target source/HTML, math and fonts, and
heading geometry in the real clipped native viewport. Additional cases change
font/width and reject a reset after same-row scrolling and subsequent resize.
Native programmatic scrolling is not a physical wheel/momentum/gesture test.

No private history factory or shipping test API is linked. Read-only Mirror of
the actual WK owner fails closed on changed typed readiness/source State fields.
Each fresh fake library has empty profiles and preserves complete project,
canonical file, saved-note, source and unsent-draft bytes. No real library,
installed App, AI, general clipboard, FPS or performance claim is involved.


## Bounded hidden CSS regression

    python3 scripts/mac-markdown/run-bounded-idle-probe.py \
      --workspace "$PWD" --build-dir .build/tests/debug --product-source-root "$PWD" \
      --output-dir logs/ci-markdown-bridge/bounded-idle --run --show-window

This additional foreground native regression links the same completed testable
Debug objects. The explicit source root is the actual compiled checkout;
five source files and all linked objects are fingerprinted and checked for
concurrent changes. The child receives only a probe-specific source-root
environment binding, not any diagnostic control/candidate arm. Product code needs no benchmark router or same-file test appendix.

The frozen12-name contract binds the exact Swift source. Checks are added only
when actually executed, with actual results; partial execution cannot pass.
The runner requires exact unique check and executed-name sets, exit0 and zero
native warning patterns. Existing bridge29/input152/history70 commands remain independent and
unchanged. No rejected byte-comparison candidate or extra internal kernel API
is required by this standalone CSS regression.

The probe uses real RichMarkdownView/WK, exact source/DOM/Range/native menu and
read-only ownership/scheduler evidence. Integer native monotonic clocks observe
idle120, first-window250, same-tuple refresh and deadline during a real unfinished
WebKit call. A controlled750ms remote JS busy segment and one intentional JS
failure exercise correctness paths only; neither is optimization evidence.
The expected message "Owned bounded-idle failure control" is not an unexpected
test failure. First-document acknowledgement, active/focus priority, source and
permission cancellation, stale generations, teardown and an actual visible
independent sheet are covered. Actual Notes/callsite leaf scope is static source
evidence; existing native Notes/Undo and other source guards stay mandatory.

Focus is held until its real native clip becomes naturally visible; the probe
does not scroll the target into place. Raw intermediate geometry and uptime are
preserved. Timing acceptance includes stated scheduling/observation jitter and
is not a WebKit completion SLA or a performance claim. No installed App, real
library, provider, general clipboard or physical input is used.
