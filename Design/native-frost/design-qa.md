# 0.17.2 · 标题与交互收拢的原生对照状态

原生视觉、手势和性能验收：**待 Mac**。构建与下载包核对：**通过**。[0.17.2/build22 安装包](../../dist/download-40067031262/ReadingBook-macos-universal.zip)来自源码 `32ec4d2a8ce0450f86983e72e5ec06bbfb947a43`；[Actions 40067031262](https://github.com/theincrediblewwz/readingbook/actions/runs/40067031262) 成功，256 项 Core 测试零失败，arm64/x86_64 Release 通过。包内 32 个资源核对通过，含 20 个公式字体；ZIP SHA-256：`875b9b9fdd3786fafe978a4bed1d37f061ce28443cb72b16d8198ba4f91ccf88`。

本轮原生仅移除重复拖柄，标题继续承担拖动，收起、关闭与辅助功能名称保留；导航悬停状态局部化，地图时间边界改为一次计算。未替换全局布局，也未将菜单大改纳入 Mac 包。按根 [Mac 集中清单](../../MAC_TEST_CHECKLIST.md) 顶部 5 步核对标题拖动/按钮/VoiceOver、侧栏滚动与缩窗、时空及权限边界、旧数据和回收恢复。

三种可交互布局位于独立原型入口 `?study=controls`，**尚待用户选择，未替换原生界面**。全文搜索重复计算、画布屏外连线、Markdown/PDF 装饰仅是待测性能候选，尚未认定为 Mac 卡顿根因。浏览器原型、Core 测试和编译结果均不替代 Mac 实际验收；下方历史记录保留。

---

# 0.17.1 · 全应用精修的原生对照状态

原生视觉/手势验收：**待Mac**。构建与下载包校验：**通过**。[0.17.1/build21 安装包](../../dist/download-40062140991/ReadingBook-macos-universal.zip)与[Actions 40062140991](https://github.com/theincrediblewwz/readingbook/actions/runs/40062140991)已核对，原生源码`8f35c6748d89f85d7ec80717d673193fa367c541`。256项Core检查、arm64/x86_64 Release、临时签名与资源自检通过，无编译警告。下载包15961565字节，SHA-256 `d7a9be96b2e8aa0c195da1d27a510db682cf0a0e0cf649da26747b73c41ccd98`；artifact摘要、ZIP CRC、版本/源码、架构/0755及32个资源逐字节核对通过，含20个公式字体。Mac原生视觉、手势、Liquid Glass、PDFKit与性能仍待集中验收，浏览器交互稿不替代Mac结果。 未用浏览器截图冒充Mac截图。

沿用已选霜银/钴蓝稿，精修思维导图、关系图谱、地图和笔记，并统一插件、模型配置/目录和书本方案。共享 56 点头、16 点标题、15 点正文、44 点操作区，管理层保留真实底页。全局进度使用实测控件尺寸；图谱工具可紧凑、状态可合并，节点面板/时间卡/人物卡/笔记列表按稳定矩形登记，拖动中不相互追赶。小窗人物卡约 140 点以上滚动槽、时间卡可关闭头，以及插件子编辑按父窗限尺寸均待原生核对。

按根 [Mac 清单](../../MAC_TEST_CHECKLIST.md) 的 0.17.1 顺序，采集 800×600、常规宽窗和全屏；每页至少包含默认、展开、折叠、关闭恢复，以及浮层重叠/无槽回退。插件需另拍脏草稿跨宽窄切换与保存失败，模型需拍服务恢复入口及窄窗目录，方案需拍未保存选择与更新冲突。补深色、减少动态/透明度、滚动归属、节点/端口拖动和关闭命中记录。截图中有内容不代表数据链已验收，仍需抽查真实 Markdown、关联恢复与原权限路径。

本批数据迁移为 0，不重写用户正文或原坐标；尚不宣称原生效果与设计稿完全一致。下方旧状态和证据保留为历史。

---

# 0.12.1：全宽内容与导航浮层

final result: blocked

仅Mac原生视觉/手势对照待验。已移除Workspace全局64pt左padding与detailWidth减64；地图/导图获得整个窗口。FloatingNavigationButton在position前测量48×48实际按钮，继续交给画布输入排除；不把position后的全窗口布局盒当成命中区。顶部停靠中心72，标题区96起；左侧目录恢复按钮局部下移128，底部仅相交的时间卡/状态条避让。不为此新增整页留白。

浏览器在1440×1024与800×600验证原左列区域的地图拖动、导图滚轮和导航拖动开合；这不代替Mac MapKit/NSEvent验证。源码bac77d77a0c96ba33b789df75084a7d6c01b1eb8，Actions38991699118成功；102项Core、双架构和资源检查通过，无编译警告，下载包0.12.1/build13摘要/权限/资源已核对。最新包与编译证据见根README。

---

# 0.12 原生修订：Mac对照待验

final result: blocked

此状态仅指原生视觉/手势对照。Windows不能运行SwiftUI，不把浏览器或编译当作Mac截图。用户画面在 `../2026-10-ui-study/evidence/05-user-0.11-top-islands.png`（版本来自会话，图内未显示）。两张本轮生成目标在 `../2026-10-ui-study/screens/layers.png` / `source-index.png`，浏览器对照见 `../prototype-frost/design-qa.md`。

WorkspaceView书名/AI胶囊改内容宽度；导航sidebar.left、48pt、左64pt安全带。GraphViewport/Pointer对背景/节点/端口/边标签统一原生坐标排除浮窗，侧栏/表单/其他窗口/惯性不被画布认领。伴读围绕原文、类型、解释与资料对读；索引按全书对象/别名/引句组织，精确锚点与单元依据分开，后台任务取消过期结果。完整Markdown/公式不按字符截断；真实笔记草稿、来源和恢复保留。

源码f4138d7，Actions38990324472成功：102项Core、双架构release、签名及资源检查通过，无编译警告；下载核对0.12/build12、SHA/CRC、权限与32资源。构建及安装包证据见根README的0.12节。请按MAC_TEST_CHECKLIST.md的0.12顺序采集1440/1080/800×600、深色、减少透明/动态的原生截图与手势结果，再与目标同屏比较。收到原生证据前保持blocked。

---

# 0.18 · 阅读底座全应用还原

用户选定第一套“阅读底座”，视觉基准为 `../prototype-frost/src/ControlStudy.jsx` 的 base 方案与本机 `logs/controls-study-0.17.2/01-base.png`。本次将其组织方式移入真实 SwiftUI 工作区，不只调整浏览器阅读页。

原生实现已覆盖：导航与书名合组、书本菜单内切换服务；原文底座合并翻页、目录、伴读/对话和批注，缩放与低频操作放入更多菜单。伴读/对话共享可移动、可调大小的浮卡，关闭恢复和笔记工具收进底座。地图保留单时间轴；导图、关系图谱、卡片和知识库统一成组工具，取消独立恢复按钮与重复状态岛。插件、模型目录、服务设置和书本方案使用同一管理卡头与固定操作区，背景保留原页面。

性能修正：原文目录输入状态局部化，180ms 后可取消地检索；PDF 引文按页复用文本和匹配结果；Markdown 原文标记共用一次 DOM 索引；图谱复用静态曲线并跳过屏外连线，节点面板关闭后释放预览。没有基于源码猜测“卡顿已根治”。离线 Markdown 资源回归 17 项通过，包含引用等价性、重复引用、UTF-16 选区、公式回退与窄窗；不代表 PDFKit 或原生帧率。

数据模型和书项目格式未改；真实 PDF、Markdown 保存、批注、回收恢复、节点坐标/挂载、模型 Keychain、Max 核验与 AI 写入审阅链继续使用原逻辑。隐藏对话清键盘焦点并拒绝发送，关闭服务子页不会继续锁定画布，底座取消拖动不保存临时偏移。

原生源码 `eecd71a604c1b1bd86d0ba98b16b8d21d36aa9fd`，分支 `codex/reading-dock-0.18`。[Actions 40074129325](https://github.com/theincrediblewwz/readingbook/actions/runs/40074129325) 成功：256 项 Core 测试零失败、双架构 Release 无编译警告，ZIP 摘要/CRC/版本/权限及32个资源核对通过，含20个公式字体。下载与 SHA 记录在根 README 与 Mac 测试清单。

**原生视觉与手势验收：待 Mac。** Windows 无法运行 SwiftUI/PDFKit，不能把交互稿、静态检查或 Actions 编译成功当作原生截图、Liquid Glass 或滚动性能通过。尤其需检查 800×600 下同时打开浮层、管理卡退出/草稿、PDF 页码编辑、底座拖动取消和输入焦点。

---

# 0.11 原生还原：视觉对照状态（历史）

final result: blocked

阻塞范围仅是 **Mac 原生画面的视觉/手势对照验收**。Windows 无法运行 SwiftUI App，不能把源码、浏览器图片或编译成功当作原生截图。本版原生实现与安装包已经完成，用户将在 Mac 集中验收。

## 已选视觉目标

`../2026-10-ui-study/styles/frost-silver.png` 及 `screens/` 下 map、mindmap、notes、plugins、models 五图；可操作参考为 `../prototype-frost/`。浏览器的 design-qa.md 只对该原型有效。

## 原生实现对应

| 范围 | 实现文件 / 保留的真实逻辑 |
| --- | --- |
| 全局壳、书库、导航 | WorkspaceView、FrostLibraryView、FloatingNavigationButton；真实书库、导入导出、草稿保护；新增圆点拖动、左上/左下停靠与记忆 |
| 阅读与伴读 | ReaderWorkspaceView、ReaderFloatingPanel、ReadingCompanionPanel、ReadingParallelView；PDFKit、原文定位、译注、目录、批注、真实OCR与核对 |
| 地图与图谱 | SpatialTimelineView、GraphCanvas、FloatingGraphWorkspace、GraphNodeBrowser；MapKit、共享事件/来源、单轴双端点、相机/节点和连线持久化 |
| 写作与知识 | DocumentEditorView、ChatSaveViews、KnowledgeLibraryView、ReadingAtlasView、LibrarySearchView、LibraryTrashView；真实Markdown、KaTeX、主动保存、来源、删除恢复 |
| AI与扩展 | ProviderSettingsView、PluginLibraryView、ReadingWorkflowView、ReadingLedgerView；真实服务/Keychain/Max、受控插件声明、新版本定义与逐段执行回执 |

Palette、ReadingGlass、ReadingLayout 和离线 Markdown reader.css 统一配色、间距、字号与玻璃回退。系统窗口控制仍是真实原生控件；地图继续用真实 MapKit，不将生成的示意地形用于生产地图。原有自有书页标记延续，公共操作采用 SF Symbols，与原型 Phosphor 的语义对应。

## 已有机器验证

- 最终源码：`c0a7e666afc58f6b50402d88f29fa527b616aad2`，构建分支 `codex/frost-native-0.11`。
- [Actions 38787646842](https://github.com/theincrediblewwz/readingbook/actions/runs/38787646842)：98项Core检查、双架构 release、ad hoc签名及包内资源检查通过；日志无编译警告。
- 包版本0.11.0/build11；下载后复核artifact摘要、ZIP CRC/SHA、Mach-O arm64/x86_64、0755和32个资源文件完全匹配。
- 未调用真实模型、未改书项目存储格式或改写用户正文；模型质量不是本次构建结果。

## Mac需要补的证据

按根 `MAC_TEST_CHECKLIST.md` 的0.11顺序运行。分别采集1440宽、1080宽、800×600默认/展开/收起/关闭恢复状态，将六个主要页面与目标图放到同一输入内对照；再单独放大核对字体、间距、颜色、图片/图标、文案五个表面。检查导航和面板拖动、窗口缩放、PDF选区与原句回跳、节点拖动/双击/端口，以及失败、草稿和恢复路径。还需深色、减少动态/透明度和VoiceOver。

在收到这些原生截图和操作结果前，保留本报告 blocked 状态，不宣称原生视觉已通过或与效果图完全一致。
