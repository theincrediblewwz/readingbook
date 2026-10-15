import SwiftUI
import ReadingCore

/// The same scroll owns each source/layer pair; independently scrolling columns cannot drift.
struct ReadingParallelView: View {
    @EnvironmentObject var store: AppStore
    var mode: String
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    HStack {
                        Label(mode == "layers" ? "译注阅读" : "原文与译注", systemImage: "rectangle.split.2x1").font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("回到原书") { store.readingSourceMode = "original" }.buttonStyle(.borderless).font(.caption)
                    }
                    Text("对照按原文片段排列。AI 译注另列来源；没有译注的片段保留原文，不把局部翻译算成整页已译。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(store.visibleSourceUnits) { unit in
                        ReadingParallelUnit(unit: unit, mode: mode, sideBySide: mode == "parallel" && geometry.size.width >= 820)
                    }
                }.padding(.horizontal, 28).padding(.top, 86).padding(.bottom, 32).frame(maxWidth: mode == "parallel" ? 1180 : 790).frame(maxWidth: .infinity)
            }.background(Palette.paper)
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
            Text(unit.locator).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            if sideBySide {
                HStack(alignment: .top, spacing: 28) {
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
            Text("原文").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            RichMarkdownView(markdown: unit.text, sourceText: unit.text,
                             plainText: !["md", "markdown"].contains(store.sourceFileURL?.pathExtension.lowercased() ?? "") && store.book?.ocrPages?.contains(where: { $0.page == unit.page }) != true,
                             sourceDecorations: decorations, focusedDecorationID: store.focusedReadingAnchorID,
                             onSourceDecorationTap: store.sourceDecorationTapped,
                             onSourceSelection: { selection in
                                var adjusted = selection; adjusted?.rangeLocation = selection?.rangeLocation.map { $0 + offset }
                                store.sourceReadingSelection = adjusted; if selection != nil { store.focusedReadingAnchorID = nil }
                             })
        }
    }
    private var translated: some View {
        VStack(alignment: .leading, spacing: 18) {
            if layers.isEmpty {
                Text("此片段暂无译注").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(layers) { layer in
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text(layer.title).font(.subheadline.weight(.medium)); Spacer(); Text(layer.kind == "translation" ? "译文" : "译注").font(.caption2).foregroundStyle(.secondary) }
                    Text(layer.sourceLabel).font(.caption2).foregroundStyle(.secondary)
                    MarkdownText(markdown: layer.markdown)
                    HStack {
                        Button("回到对应原句") { if let id = layer.sourceAnchorIDs.first { store.readingSourceMode = "original"; store.focusReadingAnchor(id) } }
                        Spacer()
                        Button("记一笔") { store.newReadingNote(title: layer.title, markdown: layer.markdown, anchorIDs: layer.sourceAnchorIDs) }.disabled(store.isBusy)
                    }.font(.caption).buttonStyle(.borderless)
                }.padding(16).background(Palette.accent.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }
}
