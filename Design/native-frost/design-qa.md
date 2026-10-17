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

# 0.11 原生还原：视觉对照状态

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
