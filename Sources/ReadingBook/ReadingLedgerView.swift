import SwiftUI
import ReadingCore

/// The check marks below come from host-validated receipts, never a model's
/// assertion that it has read the whole page. Source quality remains separate.
struct ReadingLedgerView: View {
    @EnvironmentObject var store: AppStore
    @State private var chosenUnitID = ""
    private var unit: SourceUnit? {
        let id = chosenUnitID.isEmpty ? (store.activeReadingUnitID ?? store.selectedUnitID) : chosenUnitID
        return store.book?.units.first { $0.id == id } ?? store.book?.units.first
    }
    var body: some View {
        if let book = store.book, let unit {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("逐段核对清单", systemImage: "checklist").font(.headline)
                    Spacer()
                    Button("定位原文") { store.navigateToUnit(unit.id); store.route = "reader" }.font(.caption)
                }
                Picker("查看单元", selection: Binding(get: { unit.id }, set: { chosenUnitID = $0 })) {
                    ForEach(book.units) { item in Text(item.locator).tag(item.id) }
                }
                ledger(unit: unit, book: book)
            }.softPanel()
        }
    }
    @ViewBuilder private func ledger(unit: SourceUnit, book: BookProject) -> some View {
        let manifest = try? ReadingLedger.paragraphs(for: unit, in: book)
        let savedReceipts = try? ReadingLedger.receipts(for: unit, in: book)
        let paragraphs = manifest ?? []
        let receipts = savedReceipts ?? []
        let acceptedIDs = Set(receipts.map(\.paragraphID))
        let status = book.coverage[unit.id]?.status ?? .pending
        Text("\(acceptedIDs.count) / \(paragraphs.count) 段已收核验回执").font(.subheadline.monospacedDigit()).foregroundStyle(Palette.accent)
        if manifest == nil || savedReceipts == nil { Text("清单或已保存回执未通过校验，旧记录保留，请检查来源版本。").font(.caption).foregroundStyle(Palette.copper) }
        if paragraphs.isEmpty {
            Text("本单元没有可读文字。请先 OCR，或对照原页确认空白；空提取不算 AI 已读。").font(.caption).foregroundStyle(.secondary)
        } else if receipts.isEmpty && (status == .completed || status == .needsReview) && !ReadingLedger.isDeferred(unitID: unit.id, in: book) {
            Text("这是没有逐段回执的历史处理结果，不计作新流程的逐段核验。").font(.caption).foregroundStyle(Palette.copper)
        }
        if ReadingLedger.isDeferred(unitID: unit.id, in: book) {
            Text("已延期，尚未读取；可补 OCR 后继续。此内容不作为已读材料进入综合。").font(.caption).foregroundStyle(Palette.copper)
        }
        ForEach(paragraphs) { paragraph in
            let receipt = receipts.first { $0.paragraphID == paragraph.id }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: acceptedIDs.contains(paragraph.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(acceptedIDs.contains(paragraph.id) ? Palette.accent : .secondary)
                    Text("第 \(paragraph.order + 1) \(paragraph.kind == "fragment" ? "片段" : "段") · 行 \(paragraph.lineStart)–\(paragraph.lineEnd)").font(.caption.weight(.medium))
                    Spacer()
                    Text(receipt == nil ? "待处理" : "已核验回执").font(.caption2).foregroundStyle(.secondary)
                }
                if let receipt {
                    Text(receipt.summary).font(.subheadline).textSelection(.enabled)
                    ForEach(Array(receipt.issues.enumerated()), id: \.offset) { _, issue in Text(issue).font(.caption).foregroundStyle(Palette.copper) }
                }
                DisclosureGroup("对照本段原文") {
                    Text(paragraph.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 7)
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(12).background(Palette.accent.opacity(receipt == nil ? 0.025 : 0.06), in: RoundedRectangle(cornerRadius: 9))
        }
        let requirements = (try? ReadingLedger.stepRequirements(for: unit, in: book)) ?? []
        if !requirements.isEmpty {
            Divider()
            Text("读书法步骤结果").font(.subheadline.weight(.medium))
            ForEach(requirements) { step in
                let result = book.readingStepResults?.first { $0.stepID == step.stepID && $0.methodHash == step.methodHash && $0.unitID == unit.id }
                VStack(alignment: .leading, spacing: 6) {
                    Label(step.stepText, systemImage: result == nil ? "circle" : "checkmark.circle.fill").font(.caption.weight(.medium))
                    if let result { Text(result.result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
        }
        Text("回执核验的是段落清单、文本版本与引句。原页提取是否完整、复述是否准确，仍可逐项对照原文检查。").font(.caption).foregroundStyle(.secondary)
    }
}
