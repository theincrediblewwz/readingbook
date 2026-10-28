import AppKit
import SwiftUI
import Foundation
import CryptoKit
@testable import ReadingBook
@testable import ReadingCore

/// Ephemeral typography preferences: no UserDefaults writes outside workspace.
private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private let gate = NSLock()
    private var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { gate.lock(); defer { gate.unlock() }; return values[key] }
    override func data(forKey key: String) -> Data? { gate.lock(); defer { gate.unlock() }; return values[key] as? Data }
    override func set(_ value: Any?, forKey key: String) { gate.lock(); defer { gate.unlock() }; values[key] = value }
}

@MainActor private final class HostedNoteModel: ObservableObject {
    @Published var markdown: String
    @Published var preview = false
    @Published var renderRevision = 0
    let session = NoteMarkdownEditorSession()
    let libraryRoot: URL
    let typography = ReadingTypographySettings(defaults: MemoryDefaults())
    var bindingWrites = 0
    var bodyPasses = 0
    init(markdown: String, libraryRoot: URL) { self.markdown = markdown; self.libraryRoot = libraryRoot }
    var binding: Binding<String> {
        Binding(get: { self.markdown }, set: { self.bindingWrites += 1; self.markdown = $0 })
    }
    func showPreview() -> Bool {
        guard session.finishEditing() else { return false }
        preview = true; return true
    }
}

@MainActor private struct HostedNoteView: View {
    @ObservedObject var model: HostedNoteModel
    var body: some View {
        let _ = model.bodyPasses += 1
        let _ = model.renderRevision
        VStack(spacing: 0) {
            HStack {
                Button("编辑") { model.preview = false }
                Button("预览") { _ = model.showPreview() }
                Text(model.preview ? "Rendered preview" : "Markdown editing")
            }.padding(12)
            ZStack {
                NoteMarkdownEditor(session: model.session, markdown: model.binding,
                    libraryRoot: model.libraryRoot, bookID: "hosted-fixture-book", documentID: nil,
                    font: .systemFont(ofSize: 16), expanded: false, editable: true, visible: !model.preview)
                    .opacity(model.preview ? 0 : 1).allowsHitTesting(!model.preview).accessibilityHidden(model.preview)
                if model.preview {
                    ScrollView { RichMarkdownView(markdown: model.markdown).padding(20) }
                        .environmentObject(model.typography)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Compile-time checked selector names only; never instantiated as a target.
@objc private protocol UndoRedoSelectors {
    func undo(_ sender: Any?)
    func redo(_ sender: Any?)
}

@main @MainActor struct HostedNoteUndoProbe {
    private static let undoAction = #selector(UndoRedoSelectors.undo(_:))
    private static let redoAction = #selector(UndoRedoSelectors.redo(_:))
    private static func hash(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func syntheticFixture() -> String {
        let opening = "# 原生撤销与重做回归\n\n保留 e\u{301}、é、🙂、公式 $x^2$ 与完整 Markdown。\n\n| 来源 | 内容 |\n| --- | --- |\n| 离线样本 | 原文与笔记均须保留 |\n\n"
        let paragraph = "这是自包含的离线测试段落。编辑、预览往返、撤销与重做都应保留完整字符和来源，不需要真实书库或模型。\n\n"
        let ending = "\n\n[回到原文](readingbook://book/hosted-fixture-book/unit/u1?quote=%E5%8E%9F%E6%96%87&prefix=%E5%89%8D%E6%96%87&suffix=%E5%90%8E%E6%96%87)\n\nHOSTED-NOTE-UNDO-FIXTURE-END\n"
        let target = 8471, part = Array(paragraph.utf8), tail = Array(ending.utf8)
        var bytes = Array(opening.utf8)
        while bytes.count + part.count + tail.count <= target { bytes += part }
        bytes += Array(repeating: UInt8(120), count: target - bytes.count - tail.count)
        bytes += tail
        return String(decoding: bytes, as: UTF8.self)
    }
    private static func responderType(_ object: Any?) -> String {
        object.map { String(describing: type(of: $0)) } ?? "nil"
    }
    private static func objectID(_ object: AnyObject?) -> String {
        object.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
    }
    private static func actionTarget(from first: NSResponder?, action: Selector) -> NSResponder? {
        var cursor = first, seen = Set<ObjectIdentifier>()
        while let responder = cursor, seen.insert(ObjectIdentifier(responder)).inserted {
            if responder.responds(to: action) { return responder }
            cursor = responder.nextResponder
        }
        return nil
    }
    private static func pump(_ hosting: NSView) {
        hosting.layoutSubtreeIfNeeded()
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.015))
    }
    private static func settle(_ hosting: NSView) async throws {
        for _ in 0..<12 { pump(hosting); try await Task.sleep(for: .milliseconds(15)) }
    }
    private static func snapshot(_ stage: String, model: HostedNoteModel, editor: NSTextView,
                                 window: NSWindow) -> [String: Any] {
        let menu = NSMenu(title: "Owned editor commands")
        let undo = NSMenuItem(title: "Undo", action: undoAction, keyEquivalent: "z"); undo.target = editor; menu.addItem(undo)
        let redo = NSMenuItem(title: "Redo", action: redoAction, keyEquivalent: "z"); redo.target = editor; menu.addItem(redo)
        let chainUndo = NSMenuItem(title: "Chain Undo", action: undoAction, keyEquivalent: "")
        chainUndo.target = actionTarget(from: window.firstResponder, action: undoAction); menu.addItem(chainUndo)
        menu.update()
        var chain: [[String: Any]] = [], cursor: NSResponder? = window.firstResponder, seen = Set<ObjectIdentifier>()
        while let responder = cursor, seen.insert(ObjectIdentifier(responder)).inserted, chain.count < 20 {
            chain.append(["type": responderType(responder), "undoManagerID": objectID(responder.undoManager),
                          "canUndo": responder.undoManager?.canUndo == true, "handlesUndoSelector": responder.responds(to: undoAction)])
            cursor = responder.nextResponder
        }
        let explicitTarget = NSApp.target(forAction: undoAction, to: editor, from: undo)
        let globalTarget = NSApp.target(forAction: undoAction, to: nil, from: undo)
        return ["stage": stage, "sourceBytes": editor.string.utf8.count, "sourceSHA256": hash(editor.string),
            "bindingBytes": model.markdown.utf8.count, "bindingSHA256": hash(model.markdown),
            "sourceMatchesBinding": ReadingNoteEditorContinuity.identicalSource(editor.string, model.markdown),
            "bindingWrites": model.bindingWrites, "bodyPasses": model.bodyPasses,
            "editorID": objectID(editor), "undoManagerID": objectID(editor.undoManager),
            "canUndo": editor.undoManager?.canUndo == true, "canRedo": editor.undoManager?.canRedo == true,
            "groupsByEvent": editor.undoManager?.groupsByEvent == true, "groupingLevel": editor.undoManager?.groupingLevel ?? -1,
            "firstResponderType": responderType(window.firstResponder), "firstResponderIsEditor": window.firstResponder === editor,
            "editorHidden": editor.isHiddenOrHasHiddenAncestor, "windowVisible": window.isVisible,
            "windowIsKey": window.isKeyWindow, "applicationActive": NSApp.isActive,
            "explicitUndoTarget": responderType(explicitTarget), "globalUndoTarget": responderType(globalTarget),
            "explicitMenuUndoEnabled": undo.isEnabled, "explicitMenuRedoEnabled": redo.isEnabled,
            "ownedChainUndoTarget": responderType(chainUndo.target), "ownedChainMenuUndoEnabled": chainUndo.isEnabled,
            "responderChain": chain]
    }
    private static func runCase(_ method: String, fixture: String, root: URL) async throws -> [String: Any] {
        let model = HostedNoteModel(markdown: fixture, libraryRoot: root)
        let hosting = NSHostingView(rootView: HostedNoteView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 850, height: 650)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isRestorable = false
        window.title = "Owned note undo regression (never ordered front)"
        window.contentView = hosting
        defer { window.close() }
        try await settle(hosting)
        guard let editor = model.session.scrollView.documentView as? NSTextView else { throw NSError(domain: "HostedNoteUndo", code: 1) }
        let focused = window.makeFirstResponder(editor)
        try await settle(hosting)
        var stages = [snapshot("initial", model: model, editor: editor, window: window)]
        let originalEditor = ObjectIdentifier(editor), originalManager = editor.undoManager.map(ObjectIdentifier.init)
        let suffix = "原生输入往返核验：中文与 e\u{301}。"
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        var mutationSucceeded = true
        switch method {
        case "insertText": editor.insertText(suffix, replacementRange: editor.selectedRange())
        case "privatePasteboardReadSelection":
            let pasteboard = NSPasteboard.withUniqueName()
            pasteboard.declareTypes([.string], owner: nil); pasteboard.setString(suffix, forType: .string)
            mutationSucceeded = editor.readSelection(from: pasteboard)
            pasteboard.clearContents()
        case "ownedAccessibilityValueSetter": editor.setAccessibilityValue(fixture + suffix)
        default: throw NSError(domain: "HostedNoteUndo", code: 2)
        }
        try await settle(hosting)
        let mutationProducedExpectedText = ReadingNoteEditorContinuity.identicalSource(editor.string, fixture + suffix)
        stages.append(snapshot("afterNativeMutationAndSwiftUIEcho", model: model, editor: editor, window: window))
        // Force another normal parent reconciliation, independently of whether
        // the mutation channel generated a Binding write.
        model.renderRevision += 1; try await settle(hosting)
        stages.append(snapshot("afterExplicitParentReconciliation", model: model, editor: editor, window: window))
        let previewEntered = model.showPreview()
        try await settle(hosting)
        stages.append(snapshot("renderedPreview", model: model, editor: editor, window: window))
        model.preview = false; try await settle(hosting)
        let refocused = window.makeFirstResponder(editor)
        try await settle(hosting)
        stages.append(snapshot("editingRefocusedAfterPreview", model: model, editor: editor, window: window))
        let beforeAction = editor.string
        let actionEnabled = editor.undoManager?.canUndo == true
        let target = actionTarget(from: window.firstResponder, action: undoAction)
        let standardActionSent = actionEnabled && target != nil && NSApp.sendAction(undoAction, to: target, from: nil)
        try await settle(hosting)
        stages.append(snapshot("afterExplicitResponderUndoAction", model: model, editor: editor, window: window))
        let actionChangedSource = !ReadingNoteEditorContinuity.identicalSource(beforeAction, editor.string)
        let actionRestoredFixture = ReadingNoteEditorContinuity.identicalSource(editor.string, fixture)
        var redoSent = false, redoRestoredMutation = false, directUndoRestored = false
        if actionChangedSource {
            if let redoTarget = actionTarget(from: window.firstResponder, action: redoAction) {
                redoSent = NSApp.sendAction(redoAction, to: redoTarget, from: nil)
            }
            try await settle(hosting)
            redoRestoredMutation = ReadingNoteEditorContinuity.identicalSource(editor.string, beforeAction)
            stages.append(snapshot("afterExplicitResponderRedoAction", model: model, editor: editor, window: window))
        }
        if editor.undoManager?.canUndo == true {
            editor.undoManager?.undo()
            try await settle(hosting)
            directUndoRestored = ReadingNoteEditorContinuity.identicalSource(editor.string, fixture)
        }
        stages.append(snapshot("afterDirectManagerControlUndo", model: model, editor: editor, window: window))
        let checks: [String: Bool] = [
            "ownedEditorAttachedToRealWindow": model.session.scrollView.window === window,
            "firstResponderAcceptedBeforeAndAfterPreview": focused && refocused,
            "sameEditorAndUndoManagerAfterSwiftUIPreview": ObjectIdentifier(editor) == originalEditor
                && editor.undoManager.map(ObjectIdentifier.init) == originalManager,
            "previewEntered": previewEntered,
            "windowNeverShownAndApplicationInactive": stages.allSatisfy { $0["windowVisible"] as? Bool == false && $0["applicationActive"] as? Bool == false }
        ]
        let nativeMutation = stages.first { $0["stage"] as? String == "afterNativeMutationAndSwiftUIEcho" }
        let editingAgain = stages.first { $0["stage"] as? String == "editingRefocusedAfterPreview" }
        let regressionChecks: [String: Bool] = [
            "mutationProducedExpectedText": mutationSucceeded && mutationProducedExpectedText,
            "swiftUIEchoesKeepExactSource": stages.allSatisfy { $0["sourceMatchesBinding"] as? Bool == true },
            "undoMenuEnabledAfterNativeInput": nativeMutation?["ownedChainMenuUndoEnabled"] as? Bool == true,
            "undoMenuEnabledAfterPreviewRefocus": editingAgain?["ownedChainMenuUndoEnabled"] as? Bool == true,
            "responderCommandUndoesNativeEdit": standardActionSent && actionChangedSource && actionRestoredFixture,
            "responderCommandRedoesNativeEdit": redoSent && redoRestoredMutation,
            "directManagerControlStillRestoresSource": directUndoRestored
        ]
        return ["mutationMethod": method, "mutationSucceeded": mutationSucceeded,
            "mutationProducedExpectedText": mutationProducedExpectedText,
            "observationOnly": method == "ownedAccessibilityValueSetter",
            "checks": checks, "regressionChecks": regressionChecks, "stages": stages,
            "explicitResponderUndoAttempted": actionEnabled,
            "ownedResponderChainUndoTarget": responderType(target), "ownedResponderChainRoutingCovered": target != nil,
            "explicitResponderUndoActionSent": standardActionSent, "explicitResponderUndoChangedSource": actionChangedSource,
            "explicitResponderUndoRestoredFixture": actionRestoredFixture,
            "explicitResponderRedoActionSent": redoSent, "explicitResponderRedoRestoredMutation": redoRestoredMutation,
            "directUndoManagerControlRestoredFixture": directUndoRestored,
            "nilTargetGlobalRoutingCovered": NSApp.keyWindow === window,
            "finalSourceMatchesBinding": ReadingNoteEditorContinuity.identicalSource(editor.string, model.markdown)]
    }

    static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let arguments = CommandLine.arguments
        guard arguments.count == 2 || arguments.count == 3 else { throw NSError(domain: "HostedNoteUndo", code: 3) }
        let output = URL(fileURLWithPath: arguments[1]).standardizedFileURL
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
        guard output.path.hasPrefix(workspace.path + "/") else { throw NSError(domain: "HostedNoteUndo", code: 4) }
        let fixture: String
        if arguments.count == 3 {
            let fixturePath = URL(fileURLWithPath: arguments[2]).standardizedFileURL
            guard fixturePath.path.hasPrefix(workspace.path + "/") else { throw NSError(domain: "HostedNoteUndo", code: 4) }
            let input = try Data(contentsOf: fixturePath)
            if fixturePath.pathExtension == "json" {
                guard let value = (try JSONSerialization.jsonObject(with: input) as? [String: Any])?["markdown"] as? String else { throw NSError(domain: "HostedNoteUndo", code: 5) }
                fixture = value
            } else { fixture = String(decoding: input, as: UTF8.self) }
        } else { fixture = syntheticFixture() }
        var cases: [[String: Any]] = []
        for method in ["insertText", "privatePasteboardReadSelection", "ownedAccessibilityValueSetter"] {
            cases.append(try await runCase(method, fixture: fixture, root: output.deletingLastPathComponent().appendingPathComponent("fixture-library")))
        }
        let required = cases.filter { $0["observationOnly"] as? Bool != true }
        let passed = required.allSatisfy { value in
            (value["checks"] as? [String: Bool])?.values.allSatisfy({ $0 }) == true
                && (value["regressionChecks"] as? [String: Bool])?.values.allSatisfy({ $0 }) == true
        }
        let result: [String: Any] = ["kind": "hosted-native-note-undo-routing-regression", "status": passed ? "passed" : "failed",
            "fixtureOrigin": arguments.count == 3 ? "explicit-workspace-fixture" : "self-contained-synthetic-8471B",
            "fixtureUTF8Bytes": fixture.utf8.count,
            "fixtureSHA256": hash(fixture), "cases": cases,
            "windowOrderedFront": false, "applicationActivated": false, "osEventsSynthesized": false,
            "generalClipboardTouched": false, "realLibraryAccessed": false,
            "limits": ["The window remains unshown and cannot provide the normal nil-target global key-window route.",
                       "Undo/redo resolve the actual owned first-responder chain and use NSApp.sendAction to its handling responder, plus real menu validation and direct-manager control.",
                       "Private readSelection is a low-level paste API, not the standard paste: action from the general clipboard.",
                       "The AX case calls the owned view's accessibilityValue setter; it does not call system Accessibility or Cua.",
                       "No OS keyboard/IME candidate UI is synthesized or claimed."]]
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output)
        print(String(decoding: data, as: UTF8.self))
        if !passed { exit(1) }
    }
}
