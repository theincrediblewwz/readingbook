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
