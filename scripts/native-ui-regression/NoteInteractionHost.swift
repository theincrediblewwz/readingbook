import AppKit
import SwiftUI
import PDFKit
@testable import ReadingCore
@testable import ReadingBook

@MainActor final class NoteInteractionRunner: NSObject, NSApplicationDelegate {
    let output: URL
    var store: AppStore!, window: NSWindow!, checks: [String: Bool] = [:], observations: [String: Any] = [:]
    var visiblePointerMonitor: Any?, visibleShowObservers: [NSObjectProtocol] = []
    var releaseTime: (event: TimeInterval, received: TimeInterval, text: String)?
    var visibleMenuTimings: [[String: Any]] = []
    var visibleInputEvents: [[String: Any]] = [], lastDragTime: TimeInterval?
    var visiblePopoverEvents: [[String: Any]] = []
    init(_ output: URL) { self.output = output }
    func applicationDidFinishLaunching(_ notification: Notification) { Task { await run() } }
    func settle(_ milliseconds: Int = 80) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
    func wait(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<80 { if predicate() { return true }; await settle(30) }; return predicate()
    }
    func editorStage(_ phase: String, started: TimeInterval) async throws -> PositionNoteEditorStageView {
        let deadline = started + 1.5
        let expectedID = try XCT(store.positionNoteRequest?.id)
        var polls = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            polls += 1
            if let stage = descendants(window.contentView!, PositionNoteEditorStageView.self).first,
               Mirror(reflecting: stage).children.first(where: { $0.label == "requestID" })?.value as? UUID == expectedID,
               PositionNoteEditorStageView.valid(stage.transitionTarget), stage.paper?.layer != nil {
                var entries = observations["editorStageReadiness"] as? [[String: Any]] ?? []
                entries.append(["phase": phase, "elapsedMS": (ProcessInfo.processInfo.systemUptime-started)*1000,
                    "requestID": expectedID.uuidString, "polls": polls, "deadlineMS": 1500])
                observations["editorStageReadiness"] = entries
                return stage
            }
            await settle(5)
        }
        observations["editorStageTimeout"] = ["phase": phase, "requestPresent": store.positionNoteRequest != nil,
            "error": store.errorMessage ?? "", "route": store.route,
            "stageCount": descendants(window.contentView!, PositionNoteEditorStageView.self).count,
            "elapsedMS": (ProcessInfo.processInfo.systemUptime-started)*1000]
        throw ReadingError.invalid("Current native editor did not finish first layout within1500ms: " + phase)
    }
    func descendants<T: NSView>(_ view: NSView, _: T.Type) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, T.self) } }
    func saveBitmap(_ view: NSView, _ name: String) {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: output.appendingPathComponent(name + ".png")) }
        }
    }
    func windowMenuCommand(redo: Bool) -> Bool {
        let action = NSSelectorFromString(redo ? "redo:" : "undo:")
        guard let item = (NSApp.mainMenu?.items ?? []).flatMap({ $0.submenu?.items ?? [] }).first(where: { $0.action == action }),
              let target = item.target as? ReaderEditUndoBridge.Router, target.validateMenuItem(item), let menu = item.menu else { return false }
        // A real menu opening runs validation before dispatch. Without update,
        // performActionForItem can retain its disabled, pre-edit launch state.
        observations[redo ? "redoItemEnabledBeforeUpdate" : "undoItemEnabledBeforeUpdate"] = item.isEnabled
        menu.update()
        observations[redo ? "redoItemEnabledAfterUpdate" : "undoItemEnabledAfterUpdate"] = item.isEnabled
        menu.performActionForItem(at: menu.index(of: item)); return true
    }
    func watchVisibleMenus() {
        if let pdf = descendants(window.contentView!, PDFView.self).first { pdf.allowedTouchTypes = [.indirect]; pdf.wantsRestingTouches = true }
        visiblePointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .gesture]) { [weak self] event in
            if let self, event.window === self.window {
                if event.type == .leftMouseDown { self.lastDragTime = nil }
                if event.type == .leftMouseDragged { self.lastDragTime = event.timestamp }
                var value: [String: Any] = ["type": event.type.rawValue, "eventTime": event.timestamp, "receivedTime": ProcessInfo.processInfo.systemUptime]
                if let pdf = self.descendants(self.window.contentView!, PDFView.self).first {
                    let fields = Mirror(reflecting: pdf).children
                    value["indirectFingerCount"] = fields.first { $0.label == "indirectFingerCount" }?.value as? Int
                    if let active = fields.first(where: { $0.label == "trackpadSelection" })?.value { value["ownsTrackpadSelection"] = !Mirror(reflecting: active).children.isEmpty }
                    if [.leftMouseDown,.leftMouseDragged,.leftMouseUp].contains(event.type) {
                        value["windowPoint"] = NSStringFromPoint(event.locationInWindow)
                        let point = pdf.convert(event.locationInWindow, from: nil)
                        if let page = pdf.page(for: point, nearest: false) { value["sourcePoint"] = NSStringFromPoint(pdf.convert(point, to: page)) }
                        value["currentSelection"] = String((pdf.currentSelection?.string ?? "").prefix(256))
                    }
                }
                if [.leftMouseDown,.leftMouseDragged,.leftMouseUp].contains(event.type) { value["mouseSubtype"] = event.subtype.rawValue }
                if event.type == .gesture {
                    value["touches"] = event.touches(matching: .any, in: nil).map { ["phase": $0.phase.rawValue, "resting": $0.isResting] as [String: Any] }
                }
                if event.type == .leftMouseUp {
                    let text = self.descendants(self.window.contentView!, PDFView.self).first?.currentSelection?.string ?? ""
                    self.releaseTime = (event.timestamp, ProcessInfo.processInfo.systemUptime, text)
                    value["selection"] = text
                    if let last = self.lastDragTime { value["lastDragToReleaseMS"] = (event.timestamp-last)*1000 }
                }
                self.visibleInputEvents.append(value)
                if self.visibleInputEvents.count > 1024 { self.visibleInputEvents.removeFirst(256) }
                if event.type == .leftMouseUp || (event.type == .gesture && !event.touches(matching: [.ended,.cancelled], in: nil).isEmpty) {
                    try? JSONSerialization.data(withJSONObject: self.visibleInputEvents, options: [.prettyPrinted,.sortedKeys]).write(to: self.output.appendingPathComponent("visible-input-events.json"))
                }
            }
            return event
        }
        for name in [NSPopover.willShowNotification, NSPopover.didShowNotification] {
            visibleShowObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    let current = self.descendants(self.window.contentView!, PDFView.self).first?.currentSelection?.string ?? ""
                    self.visiblePopoverEvents.append(["phase": name.rawValue, "time": now, "selection": current])
                    try? JSONSerialization.data(withJSONObject: self.visiblePopoverEvents, options: [.prettyPrinted,.sortedKeys]).write(to: self.output.appendingPathComponent("visible-popover-events.json"))
                    guard let release = self.releaseTime, !release.text.isEmpty else { return }
                    guard now-release.received < 3 else { return }
                    self.visibleMenuTimings.append(["phase": name.rawValue, "eventToNotificationMS": (now-release.event)*1000,
                        "receivedToNotificationMS": (now-release.received)*1000, "selection": release.text])
                    try? JSONSerialization.data(withJSONObject: self.visibleMenuTimings, options: [.prettyPrinted,.sortedKeys]).write(to: self.output.appendingPathComponent("visible-selection-latency.json"))
                }
            })
        }
        Task { @MainActor in
            var previous = "", serial = 0
            while window.isVisible {
                await settle(120)
                guard let root = window.contentView, let pdf = descendants(root, PDFView.self).first,
                      let context = Mirror(reflecting: pdf).children.first(where: { $0.label == "readingContext" })?.value as? ReadingContextPopover,
                      let popover = Mirror(reflecting: context).children.first(where: { $0.label == "popover" })?.value as? NSPopover,
                      popover.isShown, let popupWindow = popover.contentViewController?.view.window else { previous = ""; continue }
                let key = NSStringFromRect(popover.positioningRect) + NSStringFromRect(popupWindow.frame)
                guard key != previous else { continue }; previous = key; serial += 1
                let pointer = window.mouseLocationOutsideOfEventStream
                let values: [String: Any] = ["positioningRect": NSStringFromRect(popover.positioningRect),
                    "popupFrame": NSStringFromRect(popupWindow.frame), "windowFrame": NSStringFromRect(window.frame),
                    "pointerWindow": NSStringFromPoint(pointer), "pointerRoot": NSStringFromPoint(root.convert(pointer, from: nil)),
                    "rootBounds": NSStringFromRect(root.bounds), "rootFrame": NSStringFromRect(root.frame), "rootFlipped": root.isFlipped,
                    "pdfBounds": NSStringFromRect(pdf.bounds), "pdfFrame": NSStringFromRect(pdf.frame), "pdfFlipped": pdf.isFlipped]
                try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("visible-menu-\(serial).json"))
            }
        }
    }
    func run() async {
        do {
            UserDefaults.standard.setVolatileDomain(["library.root.path.v1": output.appendingPathComponent("library").path,
                "service-profiles": Data("[]".utf8), "appearance.reduceMotion": false, "reader.hoverAutoTranslation": false,
                "reading.paperStyle": "warm-cotton", "NSQuitAlwaysKeepsWindows": false], forName: UserDefaults.argumentDomain)
            store = AppStore(); store.apiKey = ""; store.settings.model = ""
            let source = output.appendingPathComponent("source.pdf"); var box = CGRect(x: 0, y: 0, width: 600, height: 800)
            let context = CGContext(source as CFURL, mediaBox: &box, nil)!
            for page in 1...3 {
                context.beginPDFPage(nil); NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                for (index, text) in ["Same sentence. Same sentence.", "請問將軍，為何在此長歎？", "The selected source remains on its own page.", "Page \(page) has readable source."].enumerated() {
                    (text as NSString).draw(at: .init(x: 35, y: 720 - index * 50), withAttributes: [.font: NSFont(name: "Songti SC", size: 20)!, .foregroundColor: NSColor.black])
                }
                NSGraphicsContext.restoreGraphicsState(); context.endPDFPage()
            }
            context.closePDF()
            let originalBytes = try Data(contentsOf: source)
            var project = try await store.repository.create(BookImporter.importFile(at: source), sourceURL: source)
            for (index, style) in ["plain", "warm-cotton", "mist-white", "sage-paper"].enumerated() {
                let note = DocumentRecord(id: "n\(index)", title: "用户便签\(index)")
                project = try await store.repository.saveDocument(project: project, document: note, markdown: "第\(index)张由用户输入的纸条。 e\u{301} 👩🏽‍💻",
                    notePlacement: .init(sourceHash: project.sourceHash, unitID: project.units[0].id, page: 1, x: 0.7, y: 0.75, paperStyle: style))
            }
            store.books = [project]; store.bookID = project.id; store.selectedUnitID = project.units[0].id
            store.sourceFileURL = await store.repository.sourceURL(for: project); store.route = "reader"
            window = NSWindow(contentRect: .init(x: 120, y: 90, width: 1080, height: 740), styleMask: [.titled,.closable,.resizable,.fullSizeContentView], backing: .buffered, defer: false)
            window.title = "ReadingBook 便签与标记 · 隔离回归"; window.titlebarAppearsTransparent = true
            let main = NSMenu(), appItem = NSMenuItem(), editItem = NSMenuItem()
            appItem.submenu = NSMenu(title: "测试应用"); appItem.submenu?.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            editItem.submenu = NSMenu(title: "编辑")
            for (title, selector, key) in [("撤销", "undo:", "z"), ("重做", "redo:", "Z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
                let item = editItem.submenu!.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
                item.keyEquivalentModifierMask = .command
            }
            main.addItem(appItem); main.addItem(editItem); NSApp.mainMenu = main
            // Exercise normal motion independently of the CI runner's system
            // accessibility policy. No OS preference is changed.
            observations["systemReduceMotion"] = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            observations["fixtureReadingReduceMotion"] = false
            window.contentView = NSHostingView(rootView: WorkspaceView().environmentObject(store).environmentObject(ReadingTypographySettings())
                .environment(\.readingReduceMotion, false).modifier(ReadingPreferencesEnvironment()))
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            checks["ActualWorkspaceCreatesNativePDF"] = await wait { !self.descendants(self.window.contentView!, PDFReaderContainerView.self).isEmpty }
            let reader = try XCT(descendants(window.contentView!, PDFReaderContainerView.self).first)
            let pdfController = try XCT(Mirror(reflecting: reader).children.first { $0.label == "controller" }?.value as? PDFReaderController)
            checks["ActualPDFHasSource"] = await wait { self.descendants(reader, PDFView.self).first?.document != nil }
            let pdf = try XCT(descendants(reader, PDFView.self).first), document = try XCT(pdf.document), page = try XCT(document.page(at: 0))
            await settle(300)
            if ProcessInfo.processInfo.environment["NOTE_INTERACTION_VISIBLE"] == "1" {
                watchVisibleMenus()
                try JSONSerialization.data(withJSONObject: ["status":"ready", "realNetworkRequests":0]).write(to: output.appendingPathComponent("visible-ready.json"))
                return
            }
            var menuFrames: [[String: Any]] = []
            for count in [2, 7] {
                let menu = ReadingContextPopover(), root = window.contentView!, point = CGPoint(x: 200, y: 182.5)
                let target = window.convertToScreen(.init(origin: root.convert(point, to: nil), size: .zero)).origin
                menu.show((0..<count).map { .init(title: "菜单 \($0)", icon: "bookmark", action: {}) }, at: point, in: root)
                await settle(350)
                let popup = Mirror(reflecting: menu).children.first { $0.label == "popover" }?.value as? NSPopover
                let frame = popup?.contentViewController?.view.window?.frame ?? .zero
                let edgeDistance = min(abs(target.x-frame.minX), abs(target.x-frame.maxX), abs(target.y-frame.minY), abs(target.y-frame.maxY))
                checks["Menu\(count)RowsStaysAtRequestedScreenPoint"] = !frame.isEmpty && edgeDistance < 18 && frame.insetBy(dx: -18, dy: -18).contains(target)
                menuFrames.append(["count": count, "target": NSStringFromPoint(target), "frame": NSStringFromRect(frame), "nearestEdgeDistance": edgeDistance])
                menu.close()
            }
            observations["actualMenuFrames"] = menuFrames
            let nativeText = try XCT(page.string) as NSString
            let nativeQuote = (nativeText as String).components(separatedBy: "\n").first { $0.hasPrefix("請問將軍") } ?? ""
            let range = nativeText.range(of: nativeQuote)
            observations["nativePDFText"] = nativeText as String
            guard range.location != NSNotFound, !nativeQuote.isEmpty else { throw ReadingError.invalid("Chinese fixture text missing") }
            let glyph = page.characterBounds(at: range.location + 3), point = CGPoint(x: glyph.midX, y: glyph.midY)
            func sourceActions(_ targetPage: PDFPage, _ targetPoint: CGPoint, selection: PDFSelection? = nil) async throws -> [ReadingContextAction] {
                var current: [ReadingContextAction] = []
                guard await wait({
                    guard !self.store.isBusy else { return false }
                    current = reader.sentenceMarkActions(page: targetPage, point: targetPoint, selection: selection)
                    return !current.isEmpty
                }) else { throw ReadingError.invalid("Reader did not become interactive after saved edit") }
                return current
            }
            func pointerEvent(_ page: PDFPage, _ sourcePoint: CGPoint, type: NSEvent.EventType = .leftMouseDown) throws -> NSEvent {
                let point = pdf.convert(sourcePoint, from: page)
                return try XCT(NSEvent.mouseEvent(with: type, location: pdf.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            // Independent physical glyph positions from the fixed Songti fixture.
            // Native characterBounds indices themselves skip inserted newlines.
            let startPointer = try pointerEvent(page, .init(x: 45, y: 685)), endPointer = try pointerEvent(page, .init(x: 265, y: 685), type: .leftMouseDragged)
            let cells = try XCT(PDFNativeTextGeometry.PageMap(page: page))
            checks["EveryPhysicalChineseCellTracksItsOwnNativeCharacter"] = (0..<range.length).allSatisfy {
                cells.character(at: .init(x: 45 + Double($0)*20, y: 685))?.range.location == range.location + $0
            }
            checks["ChineseCellEmptyAreasDoNotFreezeTextSelection"] = [672.0,696.0].allSatisfy { y in
                (0..<range.length).allSatisfy { cells.character(at: .init(x: 45 + Double($0)*20, y: y))?.range.location == range.location + $0 }
            }
            var forward = try XCT(PDFTrackpadTextSelection(in: pdf, event: startPointer)); forward.pointer = endPointer
            var reverse = try XCT(PDFTrackpadTextSelection(in: pdf, event: endPointer)); reverse.pointer = startPointer
            checks["TrackpadSelectionForwardKeepsExactNativeQuote"] = forward.selection(in: pdf)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) == nativeQuote
            checks["TrackpadSelectionReverseKeepsExactNativeQuote"] = reverse.selection(in: pdf)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) == nativeQuote
            let nextPage = try XCT(document.page(at: 1)); forward.pointer = try pointerEvent(nextPage, .init(x: 265, y: 685), type: .leftMouseDragged)
            checks["TrackpadSelectionRetainsNativeCrossPageRanges"] = forward.selection(in: pdf)?.pages.count == 2 && forward.selection(in: pdf)?.string?.contains(nativeQuote) == true
            checks["TrackpadSelectionCannotLeakIntoAnotherDocument"] = forward.selection(in: PDFView()) == nil
            let actions = reader.sentenceMarkActions(page: page, point: point)
            observations["sentenceActions"] = actions.map(\.title)
            checks["ColdSentenceHasStraightWavyHighlightConversationAndNote"] = ["添加直线下划线", "添加波浪下划线", "添加荧光标记", "围绕所选文字对话", "为所选文字写便签", "标记样式…"].allSatisfy { title in actions.contains { $0.title == title } }
            checks["BlankPageHasNoInventedSentenceActions"] = reader.sentenceMarkActions(page: page, point: .init(x: 580, y: 30)).isEmpty
            let legacy = ReaderUnderlineAppearance(red: 0.25, green: 0.28, blue: 0.31, thickness: 0.6)
            // A helper launched again can have preferences from its last run.
            // Remove only its two explicit test presets to exercise migration.
            guard Bundle.main.bundleIdentifier == "org.readingbook.note-interaction-regression" else { throw ReadingError.invalid("Wrong test preference owner") }
            for style in ReaderAnnotationLineStyle.allCases { UserDefaults.standard.removeObject(forKey: "reader.underlineAppearance.\(style.rawValue).v1") }
            ReaderUnderlineDefaults.save(legacy)
            checks["LegacyDefaultsSeedBothStylesUntilExplicitlySet"] = ReaderAnnotationLineStyle.allCases.allSatisfy { ReaderUnderlineDefaults.value(for: $0) == legacy }
            let straightPreset = ReaderUnderlineAppearance(red: 0.16, green: 0.42, blue: 0.75, thickness: 0.5)
            let wavyPreset = ReaderUnderlineAppearance(red: 0.72, green: 0.31, blue: 0.27, thickness: 2.3, waveLength: 10)
            ReaderUnderlineDefaults.save(straightPreset, for: .straight); ReaderUnderlineDefaults.save(wavyPreset, for: .wavy)
            checks["StraightAndWavyDefaultPresetsAreIndependent"] = ReaderUnderlineDefaults.value(for: .straight) == straightPreset && ReaderUnderlineDefaults.value(for: .wavy) == wavyPreset
            try XCT(actions.first { $0.title == "添加波浪下划线" }).action()
            checks["ActualMarkActionPersistsWithoutHighlightCoupling"] = await wait { self.store.book?.readerAnnotations?.contains { $0.lineStyle == .wavy && $0.lineAppearance?.highlighter == false } == true }
            checks["WavyActionUsesWavyPreset"] = store.book?.readerAnnotations?.first { $0.lineStyle == .wavy }?.lineAppearance == wavyPreset
            checks["AnnotationActionRegistersUndo"] = !store.readerEditUndo.undoEntries.isEmpty
            window.makeFirstResponder(window)
            observations["keyWindowBeforeReadingUndo"] = window.isKeyWindow
            checks["WindowFocusFindsReadingUndo"] = windowMenuCommand(redo: false)
            checks["WindowFocusedUndoSoftRemovesMark"] = await wait { self.store.book?.readerAnnotations?.allSatisfy { $0.trashedAt != nil } == true }
            _ = await wait { !self.store.readerEditUndo.applying && !self.store.isBusy }
            observations["windowUndoState"] = ["busy": store.isBusy, "applying": store.readerEditUndo.applying,
                "error": store.errorMessage ?? "", "undoCount": store.readerEditUndo.undoEntries.count, "redoCount": store.readerEditUndo.redoEntries.count]
            checks["WindowFocusFindsReadingRedo"] = windowMenuCommand(redo: true)
            checks["WindowFocusedRedoRestoresMark"] = await wait { self.store.book?.readerAnnotations?.contains { $0.trashedAt == nil && $0.lineStyle == .wavy } == true }
            _ = await wait { !self.store.readerEditUndo.applying && !self.store.isBusy }
            window.makeFirstResponder(pdf)
            checks["NativeResponderFindsReadingUndo"] = NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil)
            checks["NativeUndoSoftRemovesLastMark"] = await wait { self.store.book?.readerAnnotations?.allSatisfy { $0.trashedAt != nil } == true }
            checks["NativeResponderFindsReadingRedo"] = NSApp.sendAction(NSSelectorFromString("redo:"), to: nil, from: nil)
            checks["NativeRedoRestoresMark"] = await wait { self.store.book?.readerAnnotations?.contains { $0.trashedAt == nil && $0.lineStyle == .wavy } == true }
            _ = await wait { !self.store.readerEditUndo.applying && !self.store.isBusy }
            // Feed the application event queue, rather than invoking a router
            // method. This covers the native key-equivalent path that a full
            // SwiftUI app can consume before its menu target is called.
            window.makeFirstResponder(window)
            for (redo, name) in [(false, "ApplicationKeyQueueCmdZUndoesReadingEdit"), (true, "ApplicationKeyQueueShiftCmdZRedoesReadingEdit")] {
                let event = try XCT(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: redo ? [.command, .shift] : .command, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: redo ? "Z" : "z",
                    charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
                NSApp.postEvent(event, atStart: false)
                checks[name] = await wait { self.store.book?.readerAnnotations?.contains { $0.lineStyle == .wavy && ($0.trashedAt == nil) == redo } == true }
                _ = await wait { !self.store.readerEditUndo.applying && !self.store.isBusy }
            }
            await settle(200) // Finish the preceding saved-mark publication before isolating menu notifications.
            if let undoItem = (NSApp.mainMenu?.items ?? []).flatMap({ $0.submenu?.items ?? [] }).first(where: { $0.action == NSSelectorFromString("undo:") }), let edit = undoItem.menu {
                let externalTarget = NSResponder()
                undoItem.target = externalTarget
                let unrelated = NSMenu(title: "Unrelated component")
                for index in 0..<100 { unrelated.addItem(withTitle: "Item \(index)", action: nil, keyEquivalent: "") }
                await settle(100)
                checks["UnrelatedMenuChangesDoNotRebindUndoTargets"] = undoItem.target === externalTarget
                let row = NSMenuItem(title: "New edit entry", action: nil, keyEquivalent: "")
                edit.addItem(row); await settle(100)
                checks["EditingMenuChangesStillBindReadingUndo"] = undoItem.target is ReaderEditUndoBridge.Router
                edit.removeItem(row)
            } else { checks["UndoMenuPreconditionAvailable"] = false }
            let refreshed = try await sourceActions(page, point)
            try XCT(refreshed.first { $0.title == "添加荧光标记" }).action()
            checks["HighlightActionMakesSeparateDurableRecord"] = await wait { (self.store.book?.readerAnnotations?.filter { $0.trashedAt == nil }.count ?? 0) == 2 }
            checks["HighlightHasItsOwnAppearance"] = store.book?.readerAnnotations?.contains { $0.lineStyle == nil && $0.highlightAppearance != nil } == true
            let previousWavy = store.book?.readerAnnotations?.first { $0.lineStyle == .wavy && $0.trashedAt == nil }
            try XCT((try await sourceActions(page, point)).first { $0.title == "添加直线下划线" }).action()
            checks["StraightActionUsesStraightPreset"] = await wait { self.store.book?.readerAnnotations?.contains { $0.lineStyle == .straight && $0.trashedAt == nil && $0.lineAppearance == straightPreset } == true }
            checks["NewPresetKeepsExistingOtherStyle"] = previousWavy != nil && store.book?.readerAnnotations?.first { $0.id == previousWavy?.id } == previousWavy
            checks["SavedMarkPublishesCurrentReaderBeforeNextAction"] = await wait {
                !self.store.isBusy && Mirror(reflecting: reader).children.first { $0.label == "canEditAnnotations" }?.value as? Bool == true
            }
            // Saved decorations are not input surfaces: their hit paths must
            // still reach PDFKit's scroll view in every supported reading mode.
            for (name, direction, continuous, paper, width) in [
                ("VerticalContinuousWidth", PDFReadingDirection.vertical, true, false, true),
                ("HorizontalContinuousPage", .horizontal, true, false, false),
                ("VerticalSingleWidth", .vertical, false, false, true),
                ("HorizontalSingleWidth", .horizontal, false, false, true),
                ("HorizontalSinglePage", .horizontal, false, false, false),
                ("PaperBook", .horizontal, false, true, false)
            ] {
                pdfController.command(.setPaperBook(false)); pdfController.command(.setDirection(direction))
                pdfController.command(.setContinuous(continuous)); pdfController.command(width ? .fitWidth : .fitPage)
                if paper { pdfController.command(.setPaperBook(true)) }
                pdfController.command(.jump(1)); await settle(160)
                for record in store.book?.readerAnnotations?.filter({ $0.trashedAt == nil }) ?? [] {
                    guard let quad = record.quads.first, let root = window.contentView else { continue }
                    let local = pdf.convert(CGPoint(x: quad.x+quad.width/2, y: quad.y+quad.height/2), from: page)
                    let rootPoint = root.convert(local, from: pdf)
                    let hit = root.hitTest(rootPoint)
                    let kind = record.lineStyle?.rawValue ?? "highlight"
                    checks["SavedMarkPassesToNativeScroll-\(name)-\(kind)"] = hit !== pdf && hit?.isDescendant(of: pdf) == true && hit?.enclosingScrollView != nil
                }
            }
            pdfController.command(.setPaperBook(false)); pdfController.command(.setDirection(.vertical))
            pdfController.command(.setContinuous(true)); pdfController.command(.fitWidth); pdfController.command(.jump(1)); await settle(160)
            let markRect = try XCT(store.book?.readerAnnotations?.first { $0.trashedAt == nil }?.quads.first)
            let markPoint = pdf.convert(CGPoint(x: markRect.x+markRect.width/2, y: markRect.y+markRect.height/2), from: page)
            let nativePoint = pdf.convert(markPoint, to: nil), eventTime = ProcessInfo.processInfo.systemUptime
            for (type, pressure) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, Float(0))] {
                NSApp.postEvent(try XCT(NSEvent.mouseEvent(with: type, location: nativePoint, modifierFlags: [], timestamp: eventTime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: pressure)), atStart: false)
            }
            await settle(180)
            checks["ClickingSavedMarkDoesNotOpenLegacyEditor"] = window.attachedSheet == nil
            var markedSelection = try XCT(PDFTrackpadTextSelection(in: pdf, event: try pointerEvent(page, .init(x: 45, y: 685))))
            markedSelection.pointer = try pointerEvent(page, .init(x: 265, y: 685), type: .leftMouseDragged)
            checks["SelectionStillCrossesSavedMarks"] = markedSelection.selection(in: pdf)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) == nativeQuote
            var oldComment = try XCT(store.book?.readerAnnotations?.first { $0.lineStyle == nil && $0.trashedAt == nil })
            oldComment.comment = String(repeating: "过去填写的批注完整保留，不能因新界面被删掉。", count: 20)
            checks["HistoricalCommentCanStillBeSavedByRepository"] = await store.saveReaderAnnotations([oldComment])
            _ = try await sourceActions(page, point)
            pdfController.command(.showAnnotations); await settle(120)
            let recordsPanel = try XCT(Mirror(reflecting: reader).children.first { $0.label == "annotationPanel" }?.value as? NSPanel)
            let recordsHost = try XCT(recordsPanel.contentView as? NSHostingView<ReaderMarkRecordsView>)
            checks["MarkRecordsAreNonmodal"] = window.attachedSheet == nil && recordsPanel.parent === window
            checks["MarkRecordsRetainCompleteHistoricalComment"] = recordsHost.rootView.model.records.contains { $0.id == oldComment.id && $0.comment == oldComment.comment }
            checks["RecordBrowserHasNoLegacyCommentEditor"] = descendants(recordsHost, NSTextView.self).allSatisfy { !$0.isEditable }
            let storedComment = try XCT(recordsHost.rootView.model.records.first { $0.id == oldComment.id })
            recordsHost.rootView.onStyle(storedComment); await settle(100)
            let stylePanel = try XCT(window.attachedSheet)
            checks["ExplicitRecordStyleUsesUnifiedMarkEditor"] = stylePanel.title == "标记样式"
            let styleHost = try XCT(stylePanel.contentView as? NSHostingView<ReaderUnderlineStyleView>)
            styleHost.rootView.onCancel(); await settle(80)
            _ = try await sourceActions(page, point)
            pdfController.command(.showAnnotations); await settle(100)
            let updatedPanel = try XCT(Mirror(reflecting: reader).children.first { $0.label == "annotationPanel" }?.value as? NSPanel)
            let stableHost = try XCT(updatedPanel.contentView as? NSHostingView<ReaderMarkRecordsView>)
            checks["RecordsSoftRemoveKeepsComment"] = await stableHost.rootView.onTrash(storedComment, true)
            _ = await wait { stableHost.rootView.model.records.contains { $0.id == oldComment.id && $0.trashedAt != nil && $0.comment == oldComment.comment } }
            checks["RecordUpdateKeepsSameHostingTree"] = updatedPanel.contentView === stableHost
            let removed = try XCT(stableHost.rootView.model.records.first { $0.id == oldComment.id })
            checks["RecordsRestoreKeepsCommentAndIdentity"] = await stableHost.rootView.onTrash(removed, false)
            _ = await wait { stableHost.rootView.model.records.contains { $0.id == oldComment.id && $0.trashedAt == nil && $0.comment == oldComment.comment } }
            checks["RecordModelUpdatesInPlaceAfterRestore"] = updatedPanel.contentView === stableHost && stableHost.rootView.model.records.contains { $0.id == oldComment.id && $0.trashedAt == nil && $0.comment == oldComment.comment }
            saveBitmap(stableHost, "mark-records")
            stableHost.rootView.onClose(); await settle(100)
            checks["MarkBrowserCloseRestoresReadingWindow"] = window.attachedSheet == nil && !updatedPanel.isVisible
            let beforeToolbar = store.book?.readerAnnotations ?? []
            pdf.setCurrentSelection(page.selection(for: range), animate: false)
            pdfController.command(.createHighlight); await settle(120)
            checks["ToolbarHighlightDoesNotDuplicateExistingRecord"] = store.book?.readerAnnotations == beforeToolbar && window.attachedSheet == nil
            let otherRange = nativeText.range(of: "The selected source remains on its own page.")
            pdf.setCurrentSelection(page.selection(for: otherRange), animate: false)
            pdfController.command(.createHighlight)
            checks["ToolbarHighlightSavesDirectlyWithoutForm"] = await wait { (self.store.book?.readerAnnotations?.count ?? 0) == beforeToolbar.count+1 && self.window.attachedSheet == nil }
            let toolbarRecord = try XCT(store.book?.readerAnnotations?.first { candidate in !beforeToolbar.contains { $0.id == candidate.id } })
            checks["ToolbarHighlightUsesIndependentAppearance"] = toolbarRecord.lineStyle == nil && toolbarRecord.highlightAppearance != nil && toolbarRecord.comment.isEmpty
            checks["ToolbarHighlightCanBeRecoveredAfterRemoval"] = await store.setReaderAnnotationTrashed(toolbarRecord.id, trashed: true)
            pdf.clearSelection(); await settle(120)
            // Capture the menu at the current reader revision, just as the
            // user's new right-click does after the preceding saved edits.
            observations["beforeConversation"] = ["busy": store.isBusy, "scope": store.queryScope.rawValue,
                "selection": store.sourceReadingSelection?.text ?? "", "note": store.readingContextDocumentID ?? ""]
            try XCT((try await sourceActions(page, point)).first { $0.title == "围绕所选文字对话" }).action(); await settle()
            observations["afterConversation"] = ["scope": store.queryScope.rawValue, "selection": store.sourceReadingSelection?.text ?? "",
                "note": store.readingContextDocumentID ?? "", "visible": store.readingCompanionVisible]
            checks["SentenceConversationKeepsQuoteAndSelectionScope"] = store.queryScope == .selection && store.sourceReadingSelection?.text == nativeQuote && store.readingCompanionTab == "chat" && store.readingCompanionVisible
            let currentSnapshot = try store.currentQueryTaskSnapshot()
            let quoteRanges = try currentSnapshot.sourceRanges(in: store.book!)
            checks["ConversationActuallyFreezesSelectedQuoteOnly"] = quoteRanges.count == 1 && (try quoteRanges[0].text(in: store.book!.units.first { $0.id == quoteRanges[0].unitID }!)) == nativeQuote
            store.readingContextDocumentID = "n0"; store.selectedObjectID = "n0"
            try XCT((try await sourceActions(page, point)).first { $0.title == "围绕所选文字对话" }).action(); await settle()
            checks["SourceConversationReplacesPreviouslyOpenedNoteContext"] = store.readingContextDocumentID == nil && store.selectedObjectID == nil && store.queryScope == .selection && store.sourceReadingSelection?.text == nativeQuote
            let repeated = nativeText.range(of: "Same sentence.", options: .backwards)
            let repeatBox = page.characterBounds(at: repeated.location + 3)
            try XCT((try await sourceActions(page, .init(x: repeatBox.midX, y: repeatBox.midY))).first { $0.title == "围绕所选文字对话" }).action()
            checks["RepeatedEqualSentenceHasUnambiguousConversation"] = (try? store.currentQueryTaskSnapshot()) != nil && store.selectedSourceAnchor?.utf16Location == repeated.location
            store.readingCompanionVisible = false
            try XCT((try await sourceActions(page, point)).first { $0.title == "为所选文字写便签" }).action()
            checks["SentenceNoteBindsQuoteAndExactNativeRange"] = store.positionNoteRequest?.placement?.quote?.text == nativeQuote && store.positionNoteRequest?.placement?.quote?.ranges.first?.location == range.location
            let midpoint = try XCT(PDFNativeTextGeometry.midpoint(in: range, on: page)), crop = page.readingSourceBounds(for: .cropBox)
            checks["SentenceNoteStartsAtMiddleCharacter"] = abs(midpoint.midX - 165) < 1 && abs((store.positionNoteRequest?.placement?.x ?? -1) - (midpoint.midX-crop.minX)/crop.width) < 0.0001 && abs((store.positionNoteRequest?.placement?.y ?? -1) - (midpoint.midY-crop.minY)/crop.height) < 0.0001
            if let request = store.positionNoteRequest { store.discardPositionNoteDraft(request) }; store.positionNoteRequest = nil; await settle()
            let selection = try XCT(page.selection(for: range))
            let selectedActions = try await sourceActions(page, point, selection: selection)
            checks["SelectedTextUsesSameCompleteActionSet"] = Set(selectedActions.map(\.title)) == Set((try await sourceActions(page, point)).map(\.title))
            saveBitmap(window.contentView!, "workspace-marks")
            // Exact source card geometry is passed through the actual separate
            // hosting tree. The editor stage animates a layer, not TextKit width.
            let sourceRect = window.convertToScreen(.init(x: 720, y: 460, width: 230, height: 170))
            var openingStarted = ProcessInfo.processInfo.systemUptime
            await store.editPositionNote("n0", origin: .init(screenFrame: sourceRect)); await settle(25)
            observations["editorAtOriginal25msCheck"] = ["requestPresent": store.positionNoteRequest != nil,
                "stageCount": descendants(window.contentView!, PositionNoteEditorStageView.self).count,
                "elapsedMS": (ProcessInfo.processInfo.systemUptime-openingStarted)*1000, "error": store.errorMessage ?? ""]
            let stage = try await editorStage("animated-origin", started: openingStarted)
            let actualReducedMotion = Mirror(reflecting: stage).children.first { $0.label == "reduceMotion" }?.value as? Bool
            observations["editorStageReduceMotion"] = actualReducedMotion
            checks["EditorNormalMotionFixtureAllowsAnimation"] = actualReducedMotion == false
            let start = stage.convert(window.convertFromScreen(sourceRect), from: nil)
            checks["EditorStartsFromCapturedPaperFrame"] = stage.transitionStart == start
            checks["EditorHasFiniteCenteredTarget"] = PositionNoteEditorStageView.valid(stage.transitionTarget) && abs(stage.transitionTarget.midX-stage.bounds.midX)<0.01
            let animation = stage.paper?.layer?.animation(forKey: "position-note-expand")
            checks["EditorUsesOneCompositorAnimation"] = animation != nil && animation?.duration == PositionNoteEditorStageView.duration
            var frames: [String] = []
            for _ in 0..<6 { await settle(35); if let rect = stage.paper?.layer?.presentation()?.frame { frames.append(NSStringFromRect(rect)) } }
            observations["editorPresentationFrames"] = frames
            checks["EditorShowsIntermediateExpansionFrames"] = Set(frames).count > 2
            await settle(250)
            checks["EditorFinishesAtFullPaperFrame"] = stage.paper?.frame == stage.transitionTarget && stage.paper?.layer?.animation(forKey: "position-note-expand") == nil
            let texts = descendants(stage, NSTextView.self)
            checks["EditorRetainsNativeTransparentTextView"] = texts.count == 1 && texts[0].drawsBackground == false
            if let text = texts.first {
                let savedText = text.string, historyCount = store.readerEditUndo.undoEntries.count
                window.makeFirstResponder(text); text.breakUndoCoalescing()
                text.insertText("刚输入的文字", replacementRange: .init(location: (text.string as NSString).length, length: 0))
                text.breakUndoCoalescing()
                checks["EditorTextGetsUndoBeforeReadingHistory"] = NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil)
                    && text.string == savedText && store.readerEditUndo.undoEntries.count == historyCount
                checks["EditorTextGetsRedoBeforeReadingHistory"] = NSApp.sendAction(NSSelectorFromString("redo:"), to: nil, from: nil)
                    && text.string == savedText + "刚输入的文字" && store.readerEditUndo.undoEntries.count == historyCount
            }
            let reducedStage = PositionNoteEditorStageView(frame: window.contentView!.bounds)
            window.contentView!.addSubview(reducedStage)
            reducedStage.update(id: UUID(), origin: .init(screenFrame: sourceRect), reduceMotion: true, root: AnyView(Color.clear))
            reducedStage.layoutSubtreeIfNeeded()
            checks["ReducedMotionEditorKeepsFinalFrameWithoutAnimation"] = reducedStage.transitionStart != reducedStage.transitionTarget
                && PositionNoteEditorStageView.valid(reducedStage.transitionTarget) && reducedStage.paper?.frame == reducedStage.transitionTarget
                && reducedStage.paper?.layer?.animation(forKey: "position-note-expand") == nil
            reducedStage.removeFromSuperview()
            for (index, style) in ["plain", "warm-cotton", "mist-white", "sage-paper"].enumerated() {
                if let request = store.positionNoteRequest { store.discardPositionNoteDraft(request) }; store.positionNoteRequest = nil; await settle()
                openingStarted = ProcessInfo.processInfo.systemUptime
                await store.editPositionNote("n\(index)")
                let request = try XCT(store.positionNoteRequest)
                checks["Color\(index)EditorReadsStoredPaper"] = request.placement?.paperStyle == style && PositionNoteBackground.style(request.placement?.paperStyle, inherited: "warm-cotton").rawValue == style
                saveBitmap(try await editorStage("color-\(index)", started: openingStarted), "editor-color-\(index)")
            }
            if let request = store.positionNoteRequest { store.discardPositionNoteDraft(request) }; store.positionNoteRequest = nil; await settle()
            await store.editPositionNote("n0")
            let first = store.positionNoteRequest?.id
            await store.editPositionNote("n1")
            checks["AnotherOpenCannotReplaceLiveEditor"] = store.positionNoteRequest?.id == first
            let request = try XCT(store.positionNoteRequest)
            store.positionNoteDraftBuffer = .init(requestID: request.id, text: "切书前尚未到防抖时间的新文字", placement: request.placement)
            store.bookID = nil
            checks["BookChangeCancelsEditorAndUndoOwner"] = store.positionNoteRequest == nil && store.readerEditUndo.undoEntries.isEmpty
            store.bookID = project.id; store.selectedUnitID = project.units[0].id
            await store.editPositionNote("n0")
            checks["UnflushedDraftRecoveredUnderOriginalBook"] = store.positionNoteRequest?.text == "切书前尚未到防抖时间的新文字" && store.positionNoteRequest?.recovered == true
            if let request = store.positionNoteRequest { store.discardPositionNoteDraft(request) }; store.positionNoteRequest = nil
            store.beginPositionNote(page: 9999)
            checks["InvalidExplicitPageCannotFallBackToCurrentPage"] = store.positionNoteRequest == nil
            store.beginPositionNote(page: 1)
            let newRequest = try XCT(store.positionNoteRequest)
            try await store.savePositionNote(newRequest, text: "创建与撤销的普通笔记", placement: newRequest.placement)
            let newID = try XCT(store.book?.documents.last?.id)
            checks["NewNoteRegistersUndoAndInheritsCurrentPaper"] = store.readerEditUndo.undoEntries.count == 1 && store.book?.readerCollections?.notePlacements?[newID]?.paperStyle == "warm-cotton"
            await store.readerEditUndo.apply(store: store, redo: false)
            checks["UndoCreationUsesRecoverableTrash"] = store.book?.documents.first { $0.id == newID }?.trashedAt != nil
            await store.readerEditUndo.apply(store: store, redo: true)
            checks["RedoCreationRestoresSameID"] = store.book?.activeDocuments.contains { $0.id == newID } == true
            store.performPositionNoteCommand(.trash, id: "n0", owner: WorkspacePickerOwner(store: store))
            let deletion = try XCT(store.deletionRequest); store.confirmDeletion(deletion)
            checks["ActualNoteContextDeletionCompletes"] = await wait { !self.store.isBusy && self.store.book?.documents.first { $0.id == "n0" }?.trashedAt != nil }
            await store.readerEditUndo.apply(store: store, redo: false)
            checks["UndoNoteDeletionRestoresItsPaperAndBody"] = store.book?.activeDocuments.contains { $0.id == "n0" } == true && store.book?.readerCollections?.notePlacements?["n0"]?.paperStyle == "plain"
            await store.organizeReaderCollections(.setNotePlacement("n0", nil))
            checks["UnbindRegistersSeparateUndo"] = store.activeNotePlacements["n0"] == nil
            await store.readerEditUndo.apply(store: store, redo: false)
            checks["UndoUnbindRestoresOriginalCoordinates"] = store.activeNotePlacements["n0"]?.x == 0.7 && store.activeNotePlacements["n0"]?.y == 0.75
            let policyMenu = NSMenu()
            for (title, selector) in [("ReadingBook", "orderFrontStandardAboutPanel:"), ("File", "print:"), ("Edit", "undo:"), ("View", "toggleSidebar:"), ("阅读", "ignored:"), ("工作台", "ignored:"), ("Window", "performMiniaturize:"), ("Help", "showHelp:")] {
                let item = NSMenuItem(); item.title = title; item.submenu = NSMenu(title: title); item.submenu?.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: ""); policyMenu.addItem(item)
            }
            ReadingMenuPolicy.apply(to: policyMenu)
            checks["MenuKeepsOnlyAboutEditingAndWindows"] = policyMenu.items.map(\.title) == ["ReadingBook", "Edit", "Window"]
            checks["OriginalPDFBytesRemainIdentical"] = try Data(contentsOf: source) == originalBytes
            let reopened = try await store.repository.loadAll(), final = try XCT(reopened.first)
            checks["RestartRetainsAllFourNoteColors"] = ["plain", "warm-cotton", "mist-white", "sage-paper"].enumerated().allSatisfy { final.readerCollections?.notePlacements?["n\($0.offset)"]?.paperStyle == $0.element }
            checks["NoAIWasNeededOrInvoked"] = final.chats.isEmpty && final.aiRequestHistory?.isEmpty != false
            observations["checkCount"] = checks.count
        } catch { observations["fatalError"] = String(describing: error); checks["CompletedAllNativeChecks"] = false }
        let passed = checks.values.allSatisfy { $0 }
        let record: [String: Any] = ["status": passed ? "passed" : "failed", "checks": checks, "observations": observations, "realNetworkRequests": 0]
        try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("result.json"))
        window?.orderOut(nil); NSApp.terminate(nil)
    }
    func XCT<T>(_ value: T?, file: StaticString = #fileID, line: UInt = #line) throws -> T {
        guard let value else { throw ReadingError.invalid("Required native fixture value missing at \(file):\(line)") }; return value
    }
}
@main enum NoteInteractionMain {
    @MainActor static func main() {
        let output = URL(fileURLWithPath: CommandLine.arguments[1]); let app = NSApplication.shared
        app.setActivationPolicy(.regular); let delegate = NoteInteractionRunner(output); app.delegate = delegate; app.run(); _ = delegate
    }
}
