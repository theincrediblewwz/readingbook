# ReadingBook

让自己的 AI 读书、创建知识要素、调用插件，并把阅读连接到自己写下的理解。

原生 macOS 应用，SwiftUI，macOS 15+；macOS 26 使用系统 Liquid Glass。当前为**首批源码预览：尚未完成 macOS 编译、真实模型调用和真机视觉验收**，还没有可宣称可用的安装包。

## 阅读怎样连接起来

```text
原书 → 有页/行定位的内容单元 → AI 选择读书法并顺序精读
                               ↓ 实际调用插件工具
             类型、人物/概念、事件、地点、参与者与有来源的关系
                               ↓ 共用对象 ID
             卡片 ↔ 地图与时间轴 ↔ 关系图谱 ↔ 原文依据

用户理解 / 主动保存的 AI 回答 → 真实 Markdown → 文档导图节点
```

例如读到一场战役，AI 可以创建战役事件、地点和参与人物，再把同一个事件关联到地图与时间轴；点击任何入口都围绕同一个对象展开。数学书可以使用定义、定理和证明依赖，不需要人物或地图。

## 首批源码包含

- TXT、Markdown、EPUB、文本 PDF 导入；原书保留、源摘要、页/行位置、书内搜索、书签、原始 PDF 查看。
- 预读选法、动态类型与方法、真实工具调用、顺序阅读、覆盖记录、暂停/续读、请求预算、逐层复盘与全书综合。
- 通用卡片与编辑、地图/时间窗/事件选择联动、关系图谱、可拖动和连接的文档导图、知识库搜索。
- Markdown 编辑、草稿恢复、带原文与文档引用的问答；用户主动保存回答为 .md 和节点。
- 本地声明包安装、启停、类型/方法/视图扩展；示例见 [数学精读插件](Examples/math-plugin.json)。
- 原书与 Markdown 一起导出为 `.readingbook` 目录包；导入副本分配新书籍 ID 并重写副本内书籍回链。

工具变更先在当前步骤中校验，完整结果保存后才增加覆盖率。失败或取消保留最后一次已保存结果；地图和时间轴不各存一份事件。

## 在 GitHub Actions 构建

仓库提供手动工作流 **Build macOS App**，不在每次小修改后自动打包。公开仓库、许可证与首次远端操作仍待项目所有者确认。

1. 在 GitHub 的 Actions 中选择工作流，点击 **Run workflow**。
2. 工作流在 `macos-26` / Xcode 26.6 运行核心检查、编译 arm64 和 x86_64，合并为 Universal App。
3. 成功后下载 `ReadingBook-macos-universal` artifact，解开外层 artifact，再解开其中应用 ZIP。
4. 把 `ReadingBook.app` 复制到 Mac 的应用程序目录，手动启动验收。

产物同时附 SHA-256 和源码 commit。应用包使用临时签名，没有 Developer ID / Apple 公证；首次运行可能需要在系统“隐私与安全性”中对该应用单独允许打开。不建议关闭 Gatekeeper。

Mac 本地构建（需要 Xcode 26 SDK，运行系统 macOS 15+）：

```bash
swift test --scratch-path .build/tests
bash scripts/build-macos.sh
```

## 第一次使用

1. 导入 `Examples/math-sample.md` 或自己的书。
2. 在“连接自己的 AI”填写服务地址、模型和 API Key；本机支持工具调用的兼容服务可不填密钥。
3. 点击“预读”，检查方法和 AI 选择的组件；再启动精读。预算以整个用户启动的任务计算，包含工具续轮。
4. 点击卡片或关系查看原文；在地图/时间轴中选择同一事件查看关联。
5. 写下自己的理解，或主动保存回答；在思维导图中连接节点并再次打开，确认仍是同一份 Markdown。
6. 导出书项目，在副本中导入，核对原书、文档与关联。

文本默认支持 UTF-8 与带 BOM 的 UTF-16/32。接口使用兼容 Chat Completions 的 `max_tokens`；只接受 `max_completion_tokens` 的模型当前需要额外适配，服务不支持工具调用时会明确失败。远程服务要求 HTTPS，本机 loopback 可用 HTTP。开发过程中不会自动调用模型。

## 数据与当前限制

数据位于 `~/Library/Application Support/ReadingBook/books/<book-id>/`：`project.json` 保存结构，`source/` 保留原书，`docs/*.md` 是文档正文，`.journal/` 用于中断恢复。密钥仅进入 Keychain；草稿和服务配置进入本机 UserDefaults。

- 处理覆盖不等于理解正确。引用校验只能确认原文存在，不能自动证明推断正确。
- 扫描 PDF 尚无 OCR；PDF 图片/图表/公式/双栏顺序、EPUB 嵌入资源会明确标为待核对。未识别页不能静默计作读完。
- Markdown 正文以原文保存；当前原生预览是基础 Markdown，尚无完整 KaTeX、表格与富媒体排版。
- 地图为系统 MapKit，底图需要网络。未知地点不凭空地理编码；可在地点卡中手动补坐标与依据。
- 声明包扩展现有原语。增加全新原生渲染器或模型适配器需要源码编译；首版没有任意代码热加载或插件市场。
- 现阶段未做云同步、Lumen/HistoryandKnowledge 数据兼容、商业签名或自动更新。

产品参考：[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的插件组合，[Lumen](https://github.com/theincrediblewwz/lumen) 的文档节点，以及作者本地 HistoryandKnowledge 的时空联动。本项目独立实现，未复制这些项目的源码或真实数据。

许可证待所有者确定，当前不作已获得 MIT 授权的声明。
