# Isolated native note editor regression

After the coordinated Debug build finishes, run:

```sh
python3 scripts/mac-note-editor/run-native-probe.py \
  --build-dir .build/<debug-scratch>/arm64-apple-macosx/debug \
  --output logs/mac-refinement-20261028/note-editor/native-probe.json
```

Pass the actual completed directory containing `Modules/ReadingCore.swiftmodule`
and `ReadingCore.build/`. The wrapper refuses to start a product build. It
compiles only the actual native editor and this probe against those Core
objects, and keeps its binary, module caches, tmp and evidence in the workspace.
Do not run while a coordinated performance capture or product build is active.

The probe creates an owned, unattached Cocoa editor with a synthetic note of at
least 500 KiB and five long original-position links. It records initial native
assignment and background Markdown projection separately from 60 native
`NSTextView.insertText` commits and their Binding echoes. It never forces whole
document layout to inspect/count folds; projection counts are read-only Debug
state. Noncontiguous layout is enabled and background whole-text layout disabled.

Assertions cover exact UTF-8 source, complete native copy to an ephemeral private
pasteboard, 60 native undos, editor/selection/undo retention across visibility
switches, marked-text Binding echo and commitment, and identical-ID cross-library
undo isolation. No window or OS input is created, no actual library is opened,
and the general clipboard is untouched. This measures owned Cocoa input, not
hardware keyboard delivery, IME candidate UI or rendered preview layout; inspect
those in the isolated app after the probe passes.
The Binding echo is an owned in-memory fixture closure; it does not exercise
AppStore draft persistence or represent total application input latency.

The probe also checks a separate 500 KiB plain note without any links, and
records its 60 commit/echo samples independently. Native copy uses the editor's
actual advertised pasteboard types and the declaring `writeSelection(to:types:)`
API; it never modifies or normalizes the source to make a copy check pass.
Each fresh output stem owns separate build identity/log and runtime log files;
the runner refuses to overwrite an earlier sample.

Only standalone, parser-confirmed ReadingBook Markdown link destinations fold.
The glyph map replaces the first destination glyph with an ellipsis and marks
the remaining destination glyphs `.null`; the actual text storage is unchanged.
Entering/selecting the target, beginning marked text, or explicitly expanding it
reveals its complete source. The view instance stays alive behind preview.
Structured edits invalidate old confirmation; idle background parsing applies
only to the matching revision/library/document/source. Ordinary prose edits
rebase the existing UTF-16 map without parsing the whole note on the main thread.

Apple documents `.null` as ignored for layout/display in
[GlyphProperty.null](https://developer.apple.com/documentation/appkit/nslayoutmanager/glyphproperty/null).
Its [TextKit Best Practices session](https://developer.apple.com/videos/play/wwdc2018/221/)
explains view-only glyph substitution and noncontiguous layout for large texts.

## Hosted undo/redo responder regression

The direct undo-manager test above does **not** prove that the standard Edit
menu/responder commands reach that manager. Run the separate hosted regression
against completed, testable Debug objects:

```sh
python3 scripts/mac-note-editor/run-hosted-undo-probe.py \
  --build-dir .build/tests/debug \
  --output logs/ci-note-editor/hosted-undo.json
```

No fixture path is needed in CI: the probe generates a fixed 8,471-byte synthetic
Markdown note with distinct Unicode sequences, a formula, table and local source
link. For a local reproduction only, `--fixture` can point to a workspace-local
synthetic `.md` or a checkpoint JSON containing a `markdown` string. It never
opens a library or reads provider settings.

The runner links existing product objects, excluding the launcher; it does not
build the product. All helpers share `.build/shared-module-cache/swift` and
`.build/shared-module-cache/clang`, including explicit `-Xcc`/environment cache
paths. Only the executable and runtime tmp live in `.build/hosted-note-undo-probe`.
Each output stem has independent source/build/runtime evidence and cannot be
overwritten.

This creates a real NSWindow/NSHostingView containing the actual note editor,
its SwiftUI Binding echoes and the actual RichMarkdownView preview. The window
is never ordered front and the application remains inactive. For native
`insertText` and private-pasteboard `readSelection`, it verifies exact source,
editor/manager retention through preview/edit, native Undo menu validation,
`NSApp.sendAction` to the handling responder in the owned first-responder chain,
Undo/Redo data changes, and the direct-manager control. Either required input
case failing any check makes the probe exit nonzero. The owned accessibility
value-setter channel is explicitly observation-only and does not emulate Cua.

The original failure was a real routing gap: the text view had registered edits
on its private manager but did not handle `undo:`/`redo:`; the chain reached
NSWindow's different, empty manager. Direct-manager undo therefore passed while
standard command/menu validation failed. The text view now bridges only these
two actions and validations to its existing manager, delegating all other
validation to super. Apple describes the responder/undo-manager relationship in
[Using Undo in AppKit-Based Applications](https://developer-rno.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/Articles/AppKitUndo.html).

The unshown window cannot cover the normal nil-target global key-window route.
No OS events, hardware keyboard/IME candidate UI, general clipboard, real network
or installed app are used or claimed. Foreground Edit-menu/shortcut behavior is
verified separately in the isolated application.
