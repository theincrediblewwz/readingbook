import SwiftUI

struct ReadingGuideView: View {
    var onClose: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("从一本书开始", systemImage: "book.pages").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).keyboardShortcut(.cancelAction).help("关闭使用指南")
            }.padding(24)
            Divider().opacity(0.35)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    step("01", "导入后，先读原书", "PDF 默认保留原样显示。扫描页先选择视觉模型做 OCR，识别稿和原 PDF 分开保存；看不清的地方保留疑点。导入不会自动发起模型调用。")
                    step("02", "选择智能阅读", "在右上角或左下浮窗打开智能阅读。默认让 AI 自己决定，也可组合历史、战争、小说等方式。选择当前页、当前章、全书或指定页码；发送后范围固定，不会跟随你翻页扩大。当前章按导入的章节分组，未分章 PDF 可能覆盖全书，请先核对范围。")
                    step("03", "预读方案，再确认开始", "预读只看书名、目录与开头样本，选择或制定方法、类型和组件，不算通读。查看方案后点“确认并开始分析”，AI 才会在你选定的范围逐段阅读、抽取要素并保存关联。")
                    step("04", "边读，边看线索长出来", "你可以照常翻页和查看组件。左下进度可展开，查看已保存的逐段复述、步骤和完成状态；暂停后从检查点继续。为了保护数据，同一时间只运行一个模型任务；需要编辑或另外提问时先暂停。")
                    step("05", "在不同组件中看同一对象", "例如读《三国演义》：同一人物可以出现在卡片、战役、地图和关系图里。书中有依据时，AI 保存发生时间、地点与参与关系，也能用基础元件组合本书专用页面。没有明确时间或位置就保留未知；小说叙事不会自动变成史实。")
                    step("06", "把有用的内容留下", "问答范围由你选择，可以附加笔记。普通问答只读；本次允许整理后 AI 才能创建内容，修改已有笔记先展示差异。主动保存的回答和自己的理解是真实 Markdown，导图节点引用它们。")
                    step("07", "从回收站找回来", "手动移除的卡片、事件、知识关系、导图节点与连线、组件都会进入回收站。恢复时保留原来的关联、位置和挂载；需要一起恢复的内容会先列给你确认。若同一处后来又被修改，会先保留现状和回收记录。另行回收的笔记需要单独恢复，原书与 Markdown 正文不会因这些操作改变。")
                    step("08", "找到文件，留好备份", "设置里的“存储与备份”可打开书库文件夹、复制位置、迁移和恢复。每本书的阅读导航连接原书、笔记和 AI 分析；完整备份可恢复到新目录。书库菜单的“移出书库”保留文件，“删除本机项目副本”只移入系统废纸篓，导入前原文件不动。")
                    VStack(alignment: .leading, spacing: 10) {
                        Text("进度代表什么").font(.system(size: 17, weight: .semibold))
                        Text("打勾来自已经保存的段落回执、方法步骤与出处核对；缺项不能标整页完成。这能核对处理覆盖，不能证明 AI 理解没有遗漏。全书问答的按需检索，也不等于逐页通读。")
                            .font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(6)
                        Text("左下灰色百分比是阅读位置；AI 阶段、收到的字符和组件操作单独显示，字符数不是 Token。")
                            .font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(5)
                        Text("请求或上下文预算用完会暂停。先在模型设置核对服务、协议和 Max；实际调用使用你配置的服务与额度。")
                            .font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(5)
                    }.padding(20).background(Palette.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(minWidth: 560, idealWidth: 720, maxWidth: 820, minHeight: 500, idealHeight: 740)
            .background(Palette.canvas)
    }
    private func step(_ number: String, _ title: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Text(number).font(.system(size: 13).monospacedDigit()).foregroundStyle(Palette.accent).padding(.top, 4)
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 18, weight: .semibold))
                Text(description).font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
