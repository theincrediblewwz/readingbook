import AppKit
import Foundation
import ReadingCore

/// Compile with the actual NoteMarkdownEditor.swift and frozen Debug Core
/// objects. No window, OS input, real library or general clipboard is used.
@main @MainActor struct NativeNoteEditorProbe {
    private static func milliseconds(_ start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
    private static func distribution(_ values: [Double]) -> [String: Double] {
        let sorted = values.sorted()
        func percentile(_ fraction: Double) -> Double {
            sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1)]
        }
        return ["medianMS": percentile(0.5), "p95MS": percentile(0.95), "p99MS": percentile(0.99), "maxMS": sorted.last ?? 0]
    }
    private static func fixture() -> String {
        let paragraph = String(repeating: "普通正文可以在这里继续编辑，保留全部原文和定位。", count: 4) + "\n\n"
        let target = "readingbook://book/fixture-book/unit/unit-000008?quote=" + String(repeating: "%E5%BB%BA", count: 120)
            + "&prefix=" + String(repeating: "%E5%89%8D", count: 60) + "&suffix=%E5%BE%8C"
        let link = "[回到原文](\(target))\n\n"
        let count = Int(ceil(Double(500 * 1024 - link.utf8.count * 5) / Double(paragraph.utf8.count * 5)))
        return (0..<5).map { _ in String(repeating: paragraph, count: count) + link }.joined()
            + "原始 Unicode：é / e\u{301}；CRLF 也应保留\r\n"
    }

    static func main() async throws {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let arguments = CommandLine.arguments
        guard arguments.count == 2 else { throw NSError(domain: "NoteProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pass a workspace-local JSON output path."]) }
        let output = URL(fileURLWithPath: arguments[1]).standardizedFileURL
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
        guard output.path.hasPrefix(workspace.path + "/") else { throw NSError(domain: "NoteProbe", code: 2) }
        let rootA = workspace.appendingPathComponent(".build/native-note-probe/fixture-library-a")
        let rootB = workspace.appendingPathComponent(".build/native-note-probe/fixture-library-b")
        let original = fixture(), originalBytes = Data(original.utf8)
        var echoed = original
        let session = NoteMarkdownEditorSession()
        func update(root: URL = rootA, visible: Bool = true) {
            session.update(markdown: echoed, libraryRoot: root, bookID: "fixture-book", documentID: "fixture-note",
                font: .systemFont(ofSize: 16), expanded: false, editable: true, visible: visible) { echoed = $0 }
        }
        let initStart = DispatchTime.now().uptimeNanoseconds
        update()
        let initMS = milliseconds(initStart)
        guard let editor = session.scrollView.documentView as? NSTextView else { throw NSError(domain: "NoteProbe", code: 3) }
        editor.undoManager?.groupsByEvent = false
        var checks: [String: Bool] = [:]
        checks["initialUTF8Identical"] = Data(editor.string.utf8) == originalBytes
        checks["globalSaveHelperWithoutWindowSucceeds"] = NSApp.keyWindow == nil
            && NoteMarkdownEditorSession.finishActiveEditing(libraryRoot: rootA, bookID: "fixture-book")
        let storeSource = try String(contentsOf: workspace.appendingPathComponent("Sources/ReadingBook/AppStore.swift"), encoding: .utf8)
        let commandSource = try String(contentsOf: workspace.appendingPathComponent("Sources/ReadingBook/ReadingBookApp.swift"), encoding: .utf8)
        let navigationSource = try String(contentsOf: workspace.appendingPathComponent("Sources/ReadingBook/WorkspaceView.swift"), encoding: .utf8)
        let saveStart = storeSource.range(of: "func saveCurrentDocument(")?.lowerBound ?? storeSource.endIndex
        let saveBody = String(storeSource[saveStart...].prefix(2400))
        if let helper = saveBody.range(of: "NoteMarkdownEditorSession.finishActiveEditing("),
           let snapshot = saveBody.range(of: "let savingTitle") {
            checks["universalSaveCommitsEditingBeforeSnapshot"] = helper.lowerBound < snapshot.lowerBound
        } else { checks["universalSaveCommitsEditingBeforeSnapshot"] = false }
        checks["globalCmdSSharesUniversalSave"] = commandSource.contains("await store.saveCurrentDocument()")
            && commandSource.contains(".keyboardShortcut(\"s\")")
        let navigationStart = navigationSource.range(of: "private func saveDocumentAndNavigate(")?.lowerBound ?? navigationSource.endIndex
        checks["saveAndNavigateSharesUniversalSave"] = navigationSource[navigationStart...].prefix(900).contains("await store.saveCurrentDocument()")
        let projectionStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<200 {
            if session.diagnosticLinkState.confirmed == 5 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let projectionMS = milliseconds(projectionStart)
        checks["fiveTargetsConfirmedAndFolded"] = session.diagnosticLinkState.confirmed == 5 && session.diagnosticLinkState.folded == 5
        var oldComparison: [Double] = [], literalComparison: [Double] = []
        for _ in 0..<20 {
            var started = DispatchTime.now().uptimeNanoseconds
            let oldEqual = ReadingNoteEditorContinuity.identicalSource(editor.string, echoed)
            oldComparison.append(milliseconds(started))
            started = DispatchTime.now().uptimeNanoseconds
            let left = editor.string as NSString, right = echoed as NSString
            let literalEqual = left.length == right.length && left.compare(echoed, options: .literal) == .orderedSame
            literalComparison.append(milliseconds(started))
            checks["literalComparisonMatchesExactSource"] = oldEqual && literalEqual
        }
        checks["literalComparisonRejectsCanonicalReencoding"] = ("é" as NSString).compare("e\u{301}", options: .literal) != .orderedSame

        // No ensureLayout(for:), whole-document glyph enumeration, window or
        // displayIfNeeded call is allowed in this input-timing interval.
        var commits: [Double] = [], echoes: [Double] = [], combined: [Double] = []
        let expected = NSMutableString(string: original)
        for index in 0..<60 {
            let insertion = NSRange(location: 2 + index, length: 0)
            editor.undoManager?.beginUndoGrouping()
            let started = DispatchTime.now().uptimeNanoseconds
            editor.setSelectedRange(insertion)
            editor.insertText("甲", replacementRange: insertion)
            let committed = DispatchTime.now().uptimeNanoseconds
            update()
            commits.append(Double(committed - started) / 1_000_000)
            echoes.append(milliseconds(committed))
            combined.append(milliseconds(started))
            editor.undoManager?.endUndoGrouping()
            expected.insert("甲", at: insertion.location)
        }
        checks["typedSourceAndBindingExact"] = Data(editor.string.utf8) == Data((expected as String).utf8)
            && ReadingNoteEditorContinuity.identicalSource(editor.string, echoed)
        checks["foldsRemainDuringProseTyping"] = session.diagnosticLinkState.folded == 5
        let selected = NSRange(location: 10, length: 7)
        editor.setSelectedRange(selected)
        let identity = ObjectIdentifier(editor), undoBefore = editor.undoManager?.canUndo == true
        checks["finishEditingSucceeds"] = session.finishEditing()
        update(visible: false); update(visible: true)
        checks["modeSwitchKeepsEditorSelectionUndo"] = ObjectIdentifier(editor) == identity
            && editor.selectedRange() == selected && undoBefore && editor.undoManager?.canUndo == true

        // Inspect only the first target's generated glyphs, after the complete
        // input interval. No whole-document layout is requested for this proof.
        let firstTarget = (editor.string as NSString).range(of: "readingbook://book/", options: .literal).location
        if firstTarget != NSNotFound, let layout = editor.layoutManager {
            let hidden = layout.glyphIndexForCharacter(at: firstTarget + 1)
            checks["nativeTargetGlyphActuallyNull"] = layout.propertyForGlyph(at: hidden).contains(.null)
            editor.setSelectedRange(NSRange(location: firstTarget + 1, length: 0))
            let exposed = layout.glyphIndexForCharacter(at: firstTarget + 1)
            checks["nativeTargetSelectionRevealsGlyphs"] = !layout.propertyForGlyph(at: exposed).contains(.null)
                && session.diagnosticLinkState.folded == 4
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            checks["leavingTargetRefoldsWithoutChangingSource"] = session.diagnosticLinkState.folded == 5
                && Data(editor.string.utf8) == Data((expected as String).utf8)
        }

        // Native copy goes to a private, ephemeral pasteboard, never .general.
        let pasteboard = NSPasteboard.withUniqueName()
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        let writableTypes = editor.writablePasteboardTypes
        let copied = editor.writeSelection(to: pasteboard, types: writableTypes)
        let copiedSource = pasteboard.string(forType: .string)
        checks["nativeCopyContainsFullMarkdown"] = copied
            && copiedSource.map { ReadingNoteEditorContinuity.identicalSource($0, editor.string) } == true
        let copyDiagnostics: [String: Any] = ["writeSucceeded": copied, "writableTypes": writableTypes.map(\.rawValue),
            "pasteboardTypes": (pasteboard.types ?? []).map(\.rawValue), "sourceUTF8Bytes": editor.string.utf8.count,
            "copiedUTF8Bytes": copiedSource?.utf8.count ?? -1]
        pasteboard.clearContents()
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        for _ in 0..<60 { editor.undoManager?.undo() }
        checks["sixtyNativeUndosRestoreOriginalBytes"] = Data(editor.string.utf8) == originalBytes
            && Data(echoed.utf8) == originalBytes

        // A Binding echo during real Cocoa marked text must not replace it.
        editor.undoManager?.beginUndoGrouping()
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 2, length: 0))
        let markedBytes = Data(editor.string.utf8)
        update()
        checks["markedTextSurvivesEchoAndNeverFolds"] = editor.hasMarkedText()
            && Data(editor.string.utf8) == markedBytes && session.diagnosticLinkState.folded == 0
        let committed = session.finishEditing()
        editor.undoManager?.endUndoGrouping()
        checks["previewCommitsMarkedTextWithoutLosingBytes"] = committed && !editor.hasMarkedText()
            && Data(editor.string.utf8) == markedBytes && Data(echoed.utf8) == markedBytes

        editor.undoManager?.beginUndoGrouping()
        editor.insertText("库内改动", replacementRange: NSRange(location: 0, length: 0))
        editor.undoManager?.endUndoGrouping()
        let beforeLibraryChange = Data(editor.string.utf8)
        checks["fixtureUndoExistsBeforeLibraryChange"] = editor.undoManager?.canUndo == true
        update(root: rootB)
        checks["sameIDsOtherLibraryCannotInheritUndo"] = editor.undoManager?.canUndo == false
            && Data(editor.string.utf8) == beforeLibraryChange

        let plainLine = String(repeating: "普通笔记没有原文链接，继续输入也不应有额外解析工作。", count: 4) + "\n\n"
        var plainEcho = String(repeating: plainLine, count: Int(ceil(Double(500 * 1024) / Double(plainLine.utf8.count))))
        let plainSession = NoteMarkdownEditorSession()
        func updatePlain() {
            plainSession.update(markdown: plainEcho, libraryRoot: rootA, bookID: "fixture-book", documentID: "plain-note",
                font: .systemFont(ofSize: 16), expanded: false, editable: true, visible: true) { plainEcho = $0 }
        }
        let plainStarted = DispatchTime.now().uptimeNanoseconds
        updatePlain()
        let plainInitMS = milliseconds(plainStarted)
        var plainCombined: [Double] = [], plainCommit: [Double] = [], plainBinding: [Double] = []
        if let plainEditor = plainSession.scrollView.documentView as? NSTextView {
            plainEditor.undoManager?.groupsByEvent = false
            for index in 0..<60 {
                plainEditor.undoManager?.beginUndoGrouping()
                let started = DispatchTime.now().uptimeNanoseconds
                plainEditor.setSelectedRange(NSRange(location: 2 + index, length: 0))
                plainEditor.insertText("甲", replacementRange: NSRange(location: 2 + index, length: 0))
                let committed = DispatchTime.now().uptimeNanoseconds
                updatePlain()
                plainCommit.append(Double(committed - started) / 1_000_000)
                plainBinding.append(milliseconds(committed)); plainCombined.append(milliseconds(started))
                plainEditor.undoManager?.endUndoGrouping()
            }
            checks["plainLargeNoteHasNoLinkProjection"] = plainSession.diagnosticLinkState.confirmed == 0 && plainSession.diagnosticLinkState.folded == 0
            checks["plainLargeNoteBindingExact"] = Data(plainEditor.string.utf8) == Data(plainEcho.utf8)
        }

        let result: [String: Any] = [
            "kind": "native-note-editor-isolated-regression", "status": checks.values.allSatisfy({ $0 }) ? "passed" : "failed",
            "fixtureUTF8Bytes": originalBytes.count, "ownLongLinks": 5, "typedEdits": 60,
            "initialNativeAssignmentMS": initMS, "initialBackgroundProjectionReadyMS": projectionMS,
            "nativeEditCommit": distribution(commits), "bindingEcho": distribution(echoes), "commitAndEcho": distribution(combined),
            "rawInputSamples": commits.indices.map { ["editIndex": Double($0 + 1), "nativeCommitMS": commits[$0],
                "bindingEchoMS": echoes[$0], "commitAndEchoMS": combined[$0]] },
            "firstEdit": ["nativeCommitMS": commits[0], "bindingEchoMS": echoes[0], "commitAndEchoMS": combined[0]],
            "remaining59Edits": ["nativeEditCommit": distribution(Array(commits.dropFirst())),
                "bindingEcho": distribution(Array(echoes.dropFirst())), "commitAndEcho": distribution(Array(combined.dropFirst()))],
            "comparisonCandidates": ["currentCore": distribution(oldComparison), "foundationLiteral": distribution(literalComparison)],
            "copyDiagnostics": copyDiagnostics,
            "plainNoLinks": ["fixtureUTF8Bytes": plainEcho.utf8.count - 60 * 3, "typedEdits": 60,
                "initialNativeAssignmentMS": plainInitMS, "nativeEditCommit": distribution(plainCommit),
                "bindingEcho": distribution(plainBinding), "commitAndEcho": distribution(plainCombined),
                "rawInputSamples": plainCommit.indices.map { ["editIndex": Double($0 + 1), "nativeCommitMS": plainCommit[$0],
                    "bindingEchoMS": plainBinding[$0], "commitAndEchoMS": plainCombined[$0]] }],
            "checks": checks, "wholeDocumentLayoutForced": false, "windowCreated": false,
            "localizedGlyphVerificationOutsideInputTiming": true,
            "realLibraryAccessed": false, "generalClipboardModified": false,
            "limits": ["In-process Cocoa input; does not measure hardware keyboard/IME candidate UI.",
                       "Initial source assignment/background Markdown projection are separate from per-edit latency.",
                       "No full layout or rendered preview measurement; visible UI still requires the isolated app check.",
                       "Global save routes are source-audited; key-window/title-field validation requires the isolated UI check."]
        ]
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output)
        print(String(decoding: data, as: UTF8.self))
        if !checks.values.allSatisfy({ $0 }) { exit(1) }
    }
}
