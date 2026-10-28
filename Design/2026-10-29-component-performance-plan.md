# 下一阶段：组件性能、通信与组合验证

当前功能版本已交付。后续按“组件内部 → 组件间通信 → 组合算法”逐层实测，先核查既有 PDF 滚动更新频率差异及实验条件，再安排其他组件。下面是验证计划，不是已完成清单；源码中的成本路径均为候选，不能据此宣布根因或优化收益。

用户随后将[智能阅读重叠范围、继续补齐与版本保留](2026-10-29-smart-reading-continuation-proposal.md)提到当前优先，先协商交互和完成语义；该项与第6/7/13/15类组件相连。落定后继续下方固定指针/等待条件的滚动验证，其余任务未取消。

## 首要问题：PDF 滚动更新频率与实验条件

既有0.23.10/f0记录在同书页/缩放、同窗口与 PDF 内容 ROI、同程序化滚动输入下，捕获到的 PDF 内容更新 FPS 中位：宽窗 **48.57**、窄窗 **47.14**；0.23.9对应基线为 **55.74 / 57.15**。补跑旧版 control 得到 **57.57**。这些不是已安装0.23.11的重测；继续保留各轮原始结果及记录过的条件，并核查指针、等待时间等未充分约束项。具体测量边界见[滚动协议](../scripts/mac-performance/SCROLL_FPS.md)。

这些数值是 ScreenCaptureKit 捕获帧中 PDF 内容变化的频率，包含采集开销，不等于 GPU 呈现、屏幕刷新率或触控板手势 FPS。已有 profile 显示 SwiftUI 布局工作，但尚不能指认状态点或某个组件为根因。

阶段一新增[两个单次控制与资格修正](2026-10-29-scroll-control-results.md)：指针停在PDF外、采集前确认后，旧版停用缩略图绑定为58.32，同一个f0冻结二进制为58.90。人工确认同时增加了等待时间：f0启动→滚动57.00秒，而旧三轮4.50–4.75秒，故需先分开早期与充分等待的状态。旧六轮未记录pointer/hover全程条件，全部数值仍保留；目前不能认定普遍稳态版本退化，也不能宣称问题已经修好。先固定指针和等待时间，再做同源交错对照，按证据推进下面三个候选，不急于编译消融版或改产品。

先保存现有结果，再做各自独立的诊断对照：

1. 仅暂停[状态点 Timeline](../Sources/ReadingBook/ReadingPreparationState.swift)，保留真实活动状态、颜色和提示；记录滚动期间实际活动占比。
2. 仅停用关闭浮窗内新增的[工具条宽度测量](../Sources/ReadingBook/ReadingCompanionPanel.swift)及[宽度反馈](../Sources/ReadingBook/ReaderFloatingPanel.swift)，保留页面、草稿和冻结范围。两个页面常驻在旧版已经存在，不能直接归为新原因。
3. 在隔离诊断版恢复[隐藏缩略图绑定](../Sources/ReadingBook/PDFReaderView.swift)，预热后只比较稳态滚动，判断 PDFKit 观察/失效行为是否影响捕获节奏；不得未经验证将旧绑定恢复到产品。

每项固定其余变量，验证前台、持续位移、几何跨页、原件哈希、运行期警告和采集开销；比较分布及重复性，结合主线程/相关进程样本。没有明确证据前不修改产品实现；诊断禁用功能的实验版不作为交付包。

## 16 项组件验证表

| 组件 | 主要入口 | 待测成本候选 | 验证指标 |
|---|---|---|---|
| 1. PDF、缩略图、OCR | [PDFReaderView](../Sources/ReadingBook/PDFReaderView.swift)、[NativePDFPreparationWorker](../Sources/ReadingCore/NativePDFPreparationWorker.swift)、[PDFOCR](../Sources/ReadingCore/PDFOCR.swift) | PDFKit 布局/合成、可见页准备、几何与缩略图观察关系 | 捕获内容 FPS/间隔分布、主线程样本、准备次数/耗时、内存、原生导航正确性 |
| 2. 文本原文、Markdown、公式 | [ReadingViews](../Sources/ReadingBook/ReadingViews.swift)、[MarkdownRenderer](../Sources/ReadingBook/MarkdownRenderer.swift)、[renderer.js](../Sources/ReadingBook/Resources/Markdown/renderer.js) | 重复 WebKit 更新、长表格/公式重排、高度回调 | 原生→JS→布局分段耗时、WebContent资源、更新次数、选区/源码保留 |
| 3. hover、定位、索引 | [AppStoreReadingExperience](../Sources/ReadingBook/AppStoreReadingExperience.swift)、[ReaderInlineCard](../Sources/ReadingBook/ReaderInlineCard.swift)、[NativeQuoteRangeMatcher](../Sources/ReadingCore/NativeQuoteRangeMatcher.swift) | 跨页取消/重建、重复句匹配、几何命中、无效发布 | 冷暖命中率、准备/取消/过期结果次数、句卡延迟、重复句/邻页定位正确率 |
| 4. 伴读与多层记录 | [ReadingCompanionPanel](../Sources/ReadingBook/ReadingCompanionPanel.swift)、[ReadingLayersWorkspaceView](../Sources/ReadingBook/ReadingLayersWorkspaceView.swift) | projection、排序/字典、长正文渲染、宽度 Preference | 隐藏/可见投影次数、首开/切页耗时、历史规模曲线、完整保存与范围保持 |
| 5. 对话与输入 | [ReaderAIPanel](../Sources/ReadingBook/ReaderAIPanel.swift)、[ChatSaveViews](../Sources/ReadingBook/ChatSaveViews.swift) | 隐藏页更新、历史过滤、菜单布局、附件准备 | body/历史构建次数、输入回传、发送前准备、独立取消、草稿/权限保持 |
| 6. AI 调度与后台阅读 | [AppStoreSmartReading](../Sources/ReadingBook/AppStoreSmartReading.swift)、[AIReader](../Sources/ReadingCore/AIReader.swift)、[AIRequestCoordinator](../Sources/ReadingCore/AIRequestCoordinator.swift) | 快照准备、额度排队、工具校验、串行提交 | 排队/计算/传输/提交分别计时，并发上限、取消释放、成功阶段不丢失 |
| 7. 范围检索、证据、记忆 | [QueryPreparation](../Sources/ReadingBook/QueryPreparation.swift)、[ReadingPreparedAnswer](../Sources/ReadingCore/ReadingPreparedAnswer.swift)、[ReadingQuery](../Sources/ReadingCore/ReadingQuery.swift) | 重复冻结、长历史裁剪、记忆读取、范围投影 | 缓存命中/重建、输入规模与准备耗时、实际授权范围、跨库/防剧透隔离 |
| 8. 要素卡片与知识库 | [SpatialGraphViews](../Sources/ReadingBook/SpatialGraphViews.swift)、[EntityEditView](../Sources/ReadingBook/EntityEditView.swift) | 大对象集筛选/排序、文档摘要、列表失效 | 数据量→首屏/筛选/继续加载曲线、详情响应、来源和稳定 ID 保留 |
| 9. 思维导图、关系图谱 | [GraphCanvas](../Sources/ReadingBook/GraphCanvas.swift)、[SpatialGraphViews](../Sources/ReadingBook/SpatialGraphViews.swift)、[GraphCamera](../Sources/ReadingBook/GraphCamera.swift) | 全量快照/连线构建、视口绘制、命中 | 节点/边/可见比例、快照与绘制分别计时、拖动/缩放、坐标/连线/撤销正确性 |
| 10. 时间、地图、轨迹 | [SpatialTimelineView](../Sources/ReadingBook/SpatialTimelineView.swift)、[TemporalWorkspace](../Sources/ReadingBook/TemporalWorkspace.swift)、[TemporalKnowledge](../Sources/ReadingCore/TemporalKnowledge.swift) | 时间指针重复筛选、分组、轨迹/标记构建 | 本地筛选与 MapKit/瓦片延迟分开、更新次数、选择联动、未知时间/坐标处理 |
| 11. 笔记编辑与预览 | [NoteMarkdownEditor](../Sources/ReadingBook/NoteMarkdownEditor.swift)、[ReadingNoteLinkFolds](../Sources/ReadingCore/ReadingNoteLinkFolds.swift)、[ReadingViews](../Sources/ReadingBook/ReadingViews.swift) | AppStore 发布、预览、超长链接集、持久化 | 输入→Binding→AppStore→保存分段；主进程与WebKit辅助进程分别统计；字节/选区/IME/Undo、跨库同 ID；隔离编辑器数据不代替整链路 |
| 12. 搜索与目录 | [LibrarySearchView](../Sources/ReadingBook/LibrarySearchView.swift)、[LibrarySearch](../Sources/ReadingCore/LibrarySearch.swift)、[ReaderOutlinePanel](../Sources/ReadingBook/ReaderOutlinePanel.swift)、[GraphNodeBrowser](../Sources/ReadingBook/GraphNodeBrowser.swift) | 大库原文扫描、结果摘要、目录树 | 书数/字数→扫描/排序/首屏耗时、快速输入取消、结果精确回跳；样式统一不算算法收益 |
| 13. 组合组件与全书总览 | [CompositionWorkspaceView](../Sources/ReadingBook/CompositionWorkspaceView.swift)、[CompositionRuntime](../Sources/ReadingCore/CompositionRuntime.swift)、[ReadingAtlasView](../Sources/ReadingBook/ReadingAtlasView.swift) | 多 part 重复查询、依赖失效过宽、共享投影重复 | 选择器/投影次数、局部变化影响集合、全量/缓存/增量结果一致性与总耗时 |
| 14. 插件、注册、书本方案 | [WorkspaceComponentRegistry](../Sources/ReadingBook/WorkspaceComponentRegistry.swift)、[PluginEngine](../Sources/ReadingCore/PluginEngine.swift)、[BookSchemeRuntime](../Sources/ReadingCore/BookSchemeRuntime.swift) | 大声明包核验、工具 schema 构造、启停失效 | 定义规模/核验耗时、冲突与失败回滚、旧数据兼容；不恢复数学核查或退役原文索引入口 |
| 15. 书库、导入导出、备份回收 | [LibraryRepository](../Sources/ReadingCore/LibraryRepository.swift)、[LibraryStorage](../Sources/ReadingCore/LibraryStorage.swift)、[BookImporter](../Sources/ReadingCore/BookImporter.swift)、[AppStoreStorage](../Sources/ReadingBook/AppStoreStorage.swift) | JSON/源 SHA、事务、导览物化、IO 争用 | 读取/校验/编码/写入分别计时、失败恢复、并发提交、原件/笔记/分析哈希、磁盘占用 |
| 16. 配置、工作区、浮窗与状态 | [AppStore](../Sources/ReadingBook/AppStore.swift)、[WorkspaceMemory](../Sources/ReadingBook/WorkspaceMemory.swift)、[WorkspaceView](../Sources/ReadingBook/WorkspaceView.swift)、[ReadingTypographySettings](../Sources/ReadingBook/ReadingTypographySettings.swift) | 全局发布扇出、Preference/布局反馈、偏好写入、活动动画 | 一次输入的下游更新/写入次数、隐藏页成本、恢复/减少动态、旧 owner 不回写 |

## 跨组件通信和组合算法

先画出四条端到端链路并采用统一 trace ID：翻页→索引→hover/伴读；选来源→对话→笔记；选对象→图谱/时间/组合；AI 工具→增量事务→多个视图。

- **身份与版本**：缓存、异步任务及消息至少核对库 root、bookID、sourceHash，以及相关内容/索引 revision、范围与精确锚点。不能只按对象 ID 缓存，也不能扩大授权边界换命中率。
- **失效传播**：记录一次 AppStore 发布、可见页改变或工作区 Preference 引起的实际重建集合。测得重复工作后，才评估更细粒度观察、共享投影和增量失效；不预先引入通用消息总线。
- **组合依赖**：把选择、时间窗、节点、附件与各 part 列为输入/输出依赖；比较全量、缓存和增量执行的一致性、取消语义及总成本。算法名称不作为性能证据。
- **背压与持久化**：请求额度和仓库事务分别守护并发与数据。优化不得跳过确认、冲突检测、范围校验或必要成功阶段落盘；“并发更多”不等于更快。

## 开源一手资料与后续验证

已完成一轮[7项官方资料核查](2026-10-29-component-open-source-references.md)，包含Apple、Skim、Readium Swift、Sioyek、Readest、markdown-it与GRDB，记录格式/架构、许可、可借鉴策略和适配限制。优先对照高频进度独立订阅、异步预览、导航/存储分层、请求缓存键及观察区域；未引入新依赖或复制开源实现，未做跨产品同机benchmark。

后续仍须逐项核维护与依赖成本、包体、macOS/SwiftUI/PDFKit集成、迁移和数据兼容风险；Readium当前文档是iOS/UIKit，不能当作原生Mac直接依赖。先建立本项目基准，再用最小隔离原型对照，优先验证局部设计，不为采用框架而替换已有可靠组件。

## 验收与数据保护

每项保留基线、固定输入、版本/资源指纹、原始结果、失败与排除原因、收益及代价；将功能正确性、性能、真实模型质量和硬件交互分别标记。使用隔离库和本地响应，原书、笔记、分析及必要回滚保留；新产物仍在工作目录，按现有清理规则处理重复可再生成文件。未经验证的候选保持“待测”，不写成完成。
