# ReadingBook

让自己的 AI 读书、创建知识要素、调用插件，并把阅读连接到自己写下的理解。

原生 macOS 应用，SwiftUI，macOS 15+；macOS 26 使用系统 Liquid Glass。当前为 **0.2 预览**：编译与安装包状态见 [Actions](https://github.com/theincrediblewwz/readingbook/actions/workflows/macos.yml)，真实模型调用与 Mac 真机视觉仍待验收。

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
- 大模型逐页 PDF OCR：可选缺失文本页、当前页、页码范围或所有未识别页；原页图输入视觉模型，忠实转录 Markdown / LaTeX，逐页保存、预算与暂停续跑，保留待核对状态与模型来源。
- 原生 PDF 默认打开，支持缩略图、搜索高亮、跳页、缩放、适合页面/宽度；章节栏可折叠，窄窗口自动收起章节和侧边详情。
- 离线 Markdown + KaTeX：行内/块公式、四种分隔符、AMS 多行环境、矩阵、表格、代码、深色模式；长公式只在自身区域横滚。
- 保存多套 AI 配置，切换、新建预设、删除、测试连接和选择 OCR 配置；内置 7 家服务的官方模型规格与链接，已核实的输出上限可选 Max。
- 文档与书籍回收/恢复；移除卡片、事件、画布节点、连线与组件入口。导图单击选中、拖动位置、双击/右键打开，移动不再跳走。

工具变更先在当前步骤中校验，完整结果保存后才增加覆盖率。失败或取消保留最后一次已保存结果；地图和时间轴不各存一份事件。

## 在 GitHub Actions 构建

仓库提供手动工作流 **Build macOS App**，不在每次小修改后自动打包。

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
2. 展开侧栏 AI 配置，管理/新建服务，选择模型预设并填写 API Key，保存或发送一条短文本测试。本机兼容服务可不填密钥；文本测试不能证明工具/视觉能力。
3. 扫描 PDF 先点 **OCR**，选择图像模型和页码识别；对照原页核对。再点击“预读”，检查方法和 AI 选择的组件并启动精读。预算包含工具续轮。
4. 点击卡片或关系查看原文；在地图/时间轴中选择同一事件查看关联。
5. 写下自己的理解，或主动保存回答；在思维导图中连接节点并再次打开，确认仍是同一份 Markdown。
6. 导出书项目，在副本中导入，核对原书、文档与关联。

文本默认支持 UTF-8 与带 BOM 的 UTF-16/32。兼容 Chat Completions 接口可选择 `max_tokens` 或 `max_completion_tokens`，保留工具续轮需要的 `reasoning_content`。远程服务要求 HTTPS，本机 loopback 可用 HTTP。开发过程中不会自动调用模型。模型目录的版本和官方资料见 [provider-catalog.json](Sources/ReadingBook/Resources/provider-catalog.json)，核查日期 2026-10-14；账户、区域、别名规格可能变化。Max 是输出上限，实际请求仍受上下文余量约束；未核实精确整数的规格保留未知，不猜 Max。Claude 的兼容接口与原生 Messages 功能不完全相同。

公式验收可导入 [排版示例](Examples/math-rendering-sample.md)。渲染资源全部随 `.app` 打包，不依赖在线 CDN；依赖版本、MIT 许可与文件哈希见 [第三方说明](Sources/ReadingBook/Resources/Markdown/THIRD_PARTY.md)。Markdown 不执行原始 HTML；远程图片不自动加载，本地相对图片只读取明确授权目录中的安全栅格文件。

## 数据与当前限制

数据位于 `~/Library/Application Support/ReadingBook/books/<book-id>/`：`project.json` 保存结构，`source/` 保留原书，`docs/*.md` 是文档正文，`.journal/` 用于中断恢复。密钥仅进入 Keychain；草稿和服务配置进入本机 UserDefaults。

- 处理覆盖不等于理解正确。引用校验只能确认原文存在，不能自动证明推断正确。
- OCR 使用支持图像输入的模型，服务不支持时明确失败。已有分析或笔记引用的页面不能覆盖；需要重新识别时将原书导入为新项目。图表、手写、小字、复杂排版仍需对照原页核对；不清楚内容保留标记，识别不等于阅读覆盖。
- Markdown 正文原样保存；公式使用 KaTeX 支持的 LaTeX 数学语法，不是完整 TeX 文档编译器。不支持的命令显示原式和错误；EPUB 样式/嵌入资源与任意 HTML 页面尚不完整支持。
- 书籍移至本机 `ReadingBook/trash/`，文档以回收标记保留原 `.md` 与节点，可在回收站恢复；回收文档不会进入 AI 文档检索。删除实体/事件清理结构化关系，原文和用户正文保留，此类对象没有一键恢复。移除画布节点保留文档，可重新加入导图。
- 地图为系统 MapKit，底图需要网络。未知地点不凭空地理编码；可在地点卡中手动补坐标与依据。
- 声明包扩展现有原语。增加全新原生渲染器或模型适配器需要源码编译；首版没有任意代码热加载或插件市场。
- 现阶段未做云同步、Lumen/HistoryandKnowledge 数据兼容、商业签名或自动更新。

产品参考：[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的插件组合，[Lumen](https://github.com/theincrediblewwz/lumen) 的文档节点，以及作者本地 HistoryandKnowledge 的时空联动。本项目独立实现，未复制这些项目的源码或真实数据。

源码采用 [MIT License](LICENSE)。
