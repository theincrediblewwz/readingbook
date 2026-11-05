import SwiftUI
import ReadingCore

/// One native find panel owns this temporary session. It never changes routes
/// or saves search results into the book's notes, analysis or conversation.
@MainActor final class ReaderInlineAISearchModel: ObservableObject {
    let session = WholeBookSearchSession()
    let query: String
    let hasModel: Bool
    @Published private(set) var issue = ""
    private var closed = false
    private let startSession: (WholeBookSearchSession) throws -> Void
    private let validateResult: (LibraryTextMatch) throws -> Void
    var onPick: ((LibraryTextMatch) -> Void)?

    init(query: String, snapshot: LibrarySourceSnapshot?, settings: ProviderSettings,
         start: @escaping (WholeBookSearchSession) throws -> Void,
         validateResult: @escaping (LibraryTextMatch) throws -> Void) {
        self.query = query; hasModel = !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        startSession = start; self.validateResult = validateResult
        if hasModel, let snapshot { session.prepare(query: query,snapshot: snapshot,settings: settings) }
        else { issue = "请先在模型设置中连接服务，再使用 AI 阅读全文。" }
    }
    func start() {
        guard !closed, hasModel else { return }
        issue = ""
        do { try startSession(session) } catch { issue = error.localizedDescription }
    }
    func pick(_ hit: WholeBookSearchMatch) {
        guard !closed else { return }
        do {
            try validateResult(hit.source)
            guard let page = hit.source.page, page > 0 else { throw ReadingError.invalid("这条结果没有PDF页码，无法在当前原书定位。") }
            issue = ""; onPick?(hit.source)
        } catch { issue = error.localizedDescription }
    }
    func cancel() {
        guard !closed else { return }
        closed = true; session.invalidateWork(); onPick = nil
        // Native dismantle/update can run inside a SwiftUI transaction. Stop
        // transport immediately, then publish the cleared UI after it finishes.
        Task { @MainActor [session] in session.cancel(clear: true) }
    }
}

struct ReadingAISearchLabel: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles").font(.system(size: 13,weight: .medium))
            Text("AI").font(.system(size: 12,weight: .semibold))
        }.frame(minWidth: 34)
    }
}

struct ReaderInlineAISearchView: View {
    @ObservedObject var model: ReaderInlineAISearchModel
    @ObservedObject private var session: WholeBookSearchSession
    init(model: ReaderInlineAISearchModel) { self.model=model; session=model.session }
    var body: some View {
        VStack(alignment: .leading,spacing: 8) {
            HStack(spacing: 8) {
                if session.preparing || session.running { ProgressView().controlSize(.small) }
                Text(status).font(.system(size: 13,weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                if session.running {
                    Button("停止") { session.cancel() }.buttonStyle(ReadingToolbarButtonStyle()).help("停止后保留已完成的批次，可以主动继续")
                } else if model.hasModel, session.plan != nil, !session.complete {
                    Button(session.keywords.isEmpty && session.completedBatches == 0 ? "开始 AI 查找" : "继续查找") { model.start() }
                        .buttonStyle(ReadingToolbarButtonStyle(selected: true)).accessibilityIdentifier("inline-ai-search-start")
                        .help("按当前上下文容量发送本书原文；能容纳时整本一次。先理解意图再阅读全文，会消耗本轮预算")
                }
                ReaderInformationButton(title: "AI阅读全文查找",text: "先理解你想找什么，再阅读全文；能容纳时整本一次，超过配置的保守容量才分批。估算按请求字节计算，可能高于模型实际分词。结果必须能在原文中逐字核对。准备和估算不会发送原文，点击开始才使用当前模型并消耗token。只发送本书可读原文和检索问题，不发送笔记或历史对话。停止保留本次已完成进度，关闭、改词或换书会取消；不会自动续费或自动开始下一轮。没有文字的扫描页要先识别。模型可能遗漏相关内容，用量以服务商为准。")
            }
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).help(detail)
            if !model.issue.isEmpty || !session.errorMessage.isEmpty {
                Text(model.issue.isEmpty ? session.errorMessage : model.issue).font(.system(size: 12)).foregroundStyle(.red).lineLimit(2)
                    .help(model.issue.isEmpty ? session.errorMessage : model.issue)
            }
            if session.matches.isEmpty {
                Text(session.complete ? "已读取的原文中没有找到相关内容。" : session.running ? "结果会随着读取进度出现在这里。" : "不用记得原文用词，描述你想找的意思即可。")
                    .font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity,maxHeight: .infinity,alignment: .topLeading).padding(.top,4)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(session.matches) { hit in
                            resultRow(hit)
                        }
                    }
                }.accessibilityLabel("本书 AI 查找结果")
            }
        }.frame(maxWidth: .infinity,maxHeight: .infinity,alignment: .topLeading)
    }
    private func resultRow(_ hit: WholeBookSearchMatch) -> some View {
        Button { model.pick(hit) } label: { resultContent(hit.source) }
            .buttonStyle(ReadingQuietButtonStyle())
            .accessibilityIdentifier("inline-ai-result-" + hit.id)
            .help(hit.source.quote + "\n" + hit.source.locator + "\nAI认为相关：" + hit.reason)
    }
    private func resultContent(_ hit: LibraryTextMatch) -> some View {
        HStack(spacing: 12) {
            Text(snippet(hit)).font(.system(size: 14)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(hit.locator).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).frame(maxWidth: 130, alignment: .trailing)
        }.padding(.horizontal, 10).frame(minHeight: 34)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
    private var status: String {
        session.statusDescription
    }
    private var detail: String {
        guard let plan=session.plan else { return "结果保留真实原文与位置，点击可在当前书页定位。" }
        if session.tokenCost>0 { return "\(plan.batches.count == 1 ? "整本读取" : "\(session.completedBatches)/\(plan.batches.count)批") · 已用约\(session.tokenCost.formatted()) token"+(session.limited ? " · 结果最多300处" : "") }
        return plan.readingArrangement + " · 预计\(plan.batches.count+1)次请求 · 最高约\(plan.estimatedMaximumTokens.formatted()) token"+(plan.emptyUnitCount>0 ? " · \(plan.emptyUnitCount)段暂无可读文字" : "")
    }
    private func snippet(_ hit: LibraryTextMatch) -> AttributedString {
        var value=AttributedString((hit.hasEarlierText ? "…" : "")+hit.snippetBefore)
        value.foregroundColor=Palette.ink.opacity(0.65)
        var match=AttributedString(hit.quote);match.foregroundColor=Palette.ink;match.backgroundColor=Color.yellow.opacity(0.24)
        value.append(match)
        var after=AttributedString(hit.snippetAfter+(hit.hasLaterText ? "…" : ""));after.foregroundColor=Palette.ink.opacity(0.65);value.append(after)
        return value
    }
}
