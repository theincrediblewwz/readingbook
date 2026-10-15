import SwiftUI
import ReadingCore

/// The same scroll owns each source/layer pair; independently scrolling columns cannot drift.
struct ReadingParallelView: View {
    @EnvironmentObject var store: AppStore
    var mode: String
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 16) {
                        Label(mode == "layers" ? "译注阅读" : "原文与译注", systemImage: "rectangle.split.2x1").font(.system(size: 17, weight: .semibold))
                        Spacer()
                        Button { store.readingSourceMode = "original" } label: { Label("原书", systemImage: "arrow.uturn.backward") }.buttonStyle(ReadingToolbarButtonStyle())
                    }.padding(.leading, 18).padding(.trailing, 6).padding(.vertical, 6).readingGlass(radius: 18)
                    Text("对照按原文片段排列。AI 译注另列来源；没有译注的片段保留原文，不把局部翻译算成整页已译。")
                        .font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(5)
                    ForEach(store.visibleSourceUnits) { unit in
                        ReadingParallelUnit(unit: unit, mode: mode, sideBySide: mode == "parallel" && geometry.size.width >= 820)
                    }
                }.padding(.horizontal, 28).padding(.top, 100).padding(.bottom, 100).frame(maxWidth: mode == "parallel" ? 1320 : 890).frame(maxWidth: .infinity)
            }.background(Palette.canvas)
        }
    }
}

private struct ReadingParallelUnit: View {
    @EnvironmentObject var store: AppStore
    let unit: SourceUnit
    let mode: String
    let sideBySide: Bool
    private var layers: [ReadingLayer] {
        let ids = Set(store.readingExperienceIndex.anchors.filter { $0.unitID == unit.id }.map(\.id))
        return store.readingExperienceIndex.layers.filter { !ids.isDisjoint(with: $0.sourceAnchorIDs) }
    }
    private var offset: Int {
        store.visibleSourceUnits.prefix { $0.id != unit.id }.reduce(0) { $0 + ($1.text as NSString).length }
    }
    private var hasCompleteTranslation: Bool {
        let ids = Set(layers.filter { $0.kind == "translation" }.flatMap(\.sourceAnchorIDs))
        return store.readingExperienceIndex.anchors.contains { ids.contains($0.id) && $0.unitID == unit.id && $0.quote == unit.text }
    }
    private var decorations: [SourceReadingDecoration] {
        let ids = Set(store.readingExperienceIndex.anchors.filter { $0.unitID == unit.id }.map(\.id))
        return store.sourceReadingDecorations.filter { ids.contains($0.id) }.map { value in
            var next = value; next.rangeLocation = value.rangeLocation.map { $0 - offset }; return next
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(unit.locator).font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary).padding(.horizontal, 4)
            if sideBySide {
                HStack(alignment: .top, spacing: 20) {
                    original.frame(maxWidth: .infinity, alignment: .leading)
                    translated.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                if mode != "layers" || !hasCompleteTranslation { original }
                translated
            }
        }
    }
    private var original: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("原文", systemImage: "book.pages").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
            RichMarkdownView(markdown: unit.text, sourceText: unit.text,
                             plainText: !["md", "markdown"].contains(store.sourceFileURL?.pathExtension.lowercased() ?? "") && store.book?.ocrPages?.contains(where: { $0.page == unit.page }) != true,
                             sourceDecorations: decorations, focusedDecorationID: store.focusedReadingAnchorID,
                             onSourceDecorationTap: store.sourceDecorationTapped,
                             onSourceSelection: { selection in
                                var adjusted = selection; adjusted?.rangeLocation = selection?.rangeLocation.map { $0 + offset }
                                store.sourceReadingSelection = adjusted; if selection != nil { store.focusedReadingAnchorID = nil }
                             })
        }.padding(24).background(Palette.surface.opacity(0.94), in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.line.opacity(0.8), lineWidth: 0.8))
    }
    private var translated: some View {
        VStack(alignment: .leading, spacing: 18) {
            if layers.isEmpty {
                Label("此片段暂无译注", systemImage: "text.bubble").font(.system(size: 15)).foregroundStyle(.secondary).padding(.vertical, 20)
            }
            ForEach(layers) { layer in
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text(layer.title).font(.system(size: 18, weight: .medium)); Spacer(); Text(layer.kind == "translation" ? "译文" : "译注").font(.system(size: 13)).foregroundStyle(.secondary) }
                    Text(layer.sourceLabel).font(.system(size: 13)).foregroundStyle(.secondary)
                    MarkdownText(markdown: layer.markdown)
                    HStack {
                        Button { if let id = layer.sourceAnchorIDs.first { store.readingSourceMode = "original"; store.focusReadingAnchor(id) } } label: { Label("对应原句", systemImage: "arrow.uturn.backward") }
                        Spacer()
                        Button { store.newReadingNote(title: layer.title, markdown: layer.markdown, anchorIDs: layer.sourceAnchorIDs) } label: { Label("记一笔", systemImage: "square.and.pencil") }.disabled(store.isBusy)
                    }.font(.system(size: 14)).buttonStyle(ReadingToolbarButtonStyle())
                }.padding(20).background(Palette.accent.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(Palette.surface.opacity(0.86), in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.line.opacity(0.8), lineWidth: 0.8))
    }
}
