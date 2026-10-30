> 2026-10-31：第三批0.23.24/build55已完成本机时空/组合/总览/只读图谱优化与对照，完整GitHub交付尚待本轮完成。Core局部约−19%～−42%，原生组合约−19%～−22%、总览首次约−31%、只读远缩放约−14%；全局地图未证实整体收益。详见[第三批结果](2026-10-31-temporal-composition-optimization-results.md)。

> 2026-10-31：0.23.23/build54 已同步main、发布、安装并完成原书验收。第二批覆盖卡片、知识库和共享图谱；卡片/知识库采用三处优化，两个图谱候选否决。717 Core、60具名及全部原生门禁通过。下一批时间轴、地图、轨迹、组合组件和总览，图谱远缩放成本继续跟进。详见[本批结果](2026-10-31-object-graph-optimization-results.md)。

# 下一阶段：组件性能、通信与组合验证

## 当前执行顺序：先覆盖非PDF组件（2026-10-30调整）

[第一批非PDF结果](2026-10-30-companion-chat-scheduling-results.md)已交付0.23.22；[第二批结果](2026-10-31-object-graph-optimization-results.md)已交付0.23.23，卡片/知识库减少重复筛选与逐篇元数据解析，原生Release局部查询耗时约−31%/−75%，不外推整App。共享图谱已有缓存；相机复用和曲线裁剪均未达到采用标准，保留远缩放大量节点/标签的跟进问题。下一批直接覆盖时间轴、地图、轨迹、组合组件和全书总览，PDF专项继续后续轮转。每批先审查多个相邻组件的设计、重复工作和联动，再选择有实际成本与收益依据的问题修改；源码审查、有限基线和必要对照服务于优化，不能反过来让一个候选长期占据全部排期。

| 批次 | 覆盖组件 | 首轮重点 |
| --- | --- | --- |
| 1（22已交付） | 伴读与多层记录、对话、AI调度、范围检索和记忆 | 可见/隐藏投影、历史与上下文准备、重复计算、排队与并发、取消释放、迟到结果隔离 |
| 2（23已交付） | 要素卡片、知识库、思维导图、关系图谱 | 卡片/知识库三处采用；图谱两候选否决，远缩放节点/文字实际调用栈待跟进 |
| 3（24本机通过，交付中） | 时间轴、地图、轨迹、组合组件与全书总览 | 时间筛选、标记/轨迹重建、选择联动、多个元件的共享计算；本地成本与网络/瓦片延迟分开 |
| 4 | 插件与方案、书库/导入导出/备份、设置与工作区；笔记/搜索的剩余热点 | 注册与校验、IO和保存、恢复、状态发布与隐藏组件生命周期；复查前3批的跨组件链 |

按当前范围粗估，四批第一轮约需16–32小时有效工作量（约2–4个8小时工作日），包括排查、能证明收益的改动、必要回归和交付；这是工作量估算，不是后台自动执行或日历完成日期。第一轮目标是每类都有实际审查/成本结论，并处理明确热点；不承诺每类必有性能改动，也不把一次局部优化当作整类完成。新增阻断性缺陷与复杂绘制问题可能改变耗时，须及时更新进度。

已经交付的对话输入、续读准备、时间/组合快照复用、笔记与搜索优化继续保留；这些准备链收益不代替卡片、图谱、地图等界面本身的测量。每批汇总多个组件的结果与采用/否决理由，合并一次必要的完整CI、打包、安装和清理。原书、笔记、分析和授权边界始终保持，产物复用工作区内缓存。

每批开始和编译前先交代是否有产品源码修改、涉及组件/文件数、Debug或Release、本机或GitHub、当前安装版。优先本机增量验证，多项改动合并一次完整CI与通用包发布；没有新证据或源变更不重复全量编译。增量Debug与从零双架构Release耗时分别报告，不作直接速度比较。

下方保留早期计划与历史诊断。当前顺序以上方四批为准。

下文保留先前16类组件计划；当时 **0.23.21/build52** 已合入main、发布并实际安装，最近结果见上方；[本批结果](2026-10-30-batch-optimization-results.md)记录对话输入、空历史和组合快照三项采用、固定PDF12样本及原数据核对。[组件进度](2026-10-29-performance-progress.md)记录已交付的准备链复用；当前执行顺序以上方四批为准。字号/主题候选的历史否决结论保持。其余16类与跨组件任务继续，原书/笔记/分析与必要回滚保留。

当前功能和本批性能版本已交付。后续按“组件内部 → 组件间通信 → 组合算法”逐层推进，固定PDF条件基线已补齐，按已确认的成本优先减少重复工作。下面是验证计划，不是已完成清单；源码中的成本路径均为候选，不能据此宣布根因或优化收益。

用户随后将[智能阅读重叠范围、继续补齐与版本保留](2026-10-29-smart-reading-continuation-proposal.md)提到当前优先，并已批准三种操作、默认继续补齐。实现与发布验证见[续读记录](2026-10-29-smart-reading-continuation-results.md)；该项与第6/7/13/15类组件相连。续读已交付，固定指针/等待的当前基线也已完成；下方早期候选作为历史线索保留，其余任务未取消。

续读实现期间新增了离线Debug Core成本基线：1484内容单元/100条已保存页块，三次中位整书preview 0.495s、prepare 2.247s，50–200为0.206/0.742s；计数分别100沿用/1384新增与51沿用/100新增。独立phase观察到清单合同重投影/校验重复成本，索引本身约0.004s；阶段重叠不能相加。后续先在相同证据/范围验证不减弱的条件下测试请求内共享投影，再比较原库规模曲线。该段为当时未实施优化的历史Debug观察，不能当作Release延迟或PDF FPS；后文0.23.14已用新的无插桩Release对照完成请求内摘要复用，未把这组Debug数字混作before/after。原始12样本和对象指纹留在本机logs。

## PDF历史诊断：滚动更新频率与实验条件（留待后续轮转）

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


## 同书 PDF 复用阶段（已交付0.23.13）

[完整报告](2026-10-29-samebook-pdf-results.md)记录两阶段对照、失败候选、调用栈、最终来源守护和原生回执修复。最终源码01811389的交错3+3进程：显示阅读器文档创建6→1，应用累计CPU中位23.3885→10.1070秒（-56.79%），峰值footprint483.91→372.97MiB（-22.93%），30秒footprint296.99→258.50MiB。重选280.34→298.85ms、首次伴读300.53→321.29ms，范围重叠，未证实延迟提速；未重测FPS，也不是所有后台PDF worker的构造总数。

真实8页PDF原生回归覆盖任意第4页/135%/横向单页、视口、选区/搜索、批注/笔记/分析/草稿、替换/损坏/删除/符号链接、跨库/加密会话、迟到与乱序回执及显式同步保存。最终CI40828098268的659项Core零失败/零编译警告，全部原生与工具步骤通过，三类运行警告零；0.23.13/build44已发布并安装，真实原书/已有句译/伴读对话验收，20文件原数据保留，必要回滚仍在工作区。

0.23.13留下的连续页边界currentPage与currentDestination.page分歧，已在0.23.14统一页身份与锚点坐标，并补偿PDFKit裁剪。真实native4/3失败已转通过，重选/remount/legacy/横向/旋转/crop/异常锚点均回归；实际1484页隔离副本102重选及重启保持102，既存句译保留。最终安装版第102页重选和正常重启恢复已通过；不会从任意旧保存记录硬猜用户原本想读下一页。

续读请求内摘要复用已在0.23.14实施实验A：只在一次同步projectLocalWork内绑定不可变项目与完整chunk键，不跨UI预览/开始、请求、await或历史快照。原有验证和拒绝消息全部保持。无插桩生产Core新12进程对照：50–200完整prepare0.505055→0.459226秒（-9.07%），整书1.608747→1.170943秒（-27.21%）；整书lifetime峰值+0.80MiB，小范围内存近似不变。115个Core文件与基线/候选提交逐一匹配，公开完整验证、CP/笔记/evidence/历史与精确任务/库存指纹均通过。新增5项缓存键/来源变更/伪造/新要求/重做历史测试，CI总664项通过。跨函数已认证投影的实验B未实施，不跳过公开信任边界。

下一最小候选切换到Markdown/WebKit：只读审计确认已有状态去重、single-flight、presentation/delta更新和隐藏伴读保护，避免重复优化已有能力。待测的是样式/标记更新仍携带未使用的完整正文/源文桥接字段；20KiB/512KiB两规模×A/B×3新进程比较端到端成本，并保护来源/选区/公式/DOM和滚动。原始审计在本机`logs/boundary-continuation-20261029/next-render-component-audit.md`，尚无实际收益结论，所以当前没有修改这部分产品。其余16组件、图谱地图/搜索规模曲线与后续滚动验证未取消。

本轮[Markdown/WebKit实测与交付记录](2026-10-29-markdown-bridge-results.md)已完成参数候选对照。正式新12行完整保留，失焦数据门槛与三对同向/至少5%收益门槛未通过，未采用参数裁剪，也不据代理字节量宣布提速。预检独立复现并修复了focus取消残留及SwiftUI规范等价String导致精确源文字节未传到Native的问题；152项输入身份和29项常规原生桥接检查通过。实验每次请求同时改字号和主题，短文本24请求/48次presentation可能是两次合法环境传播，不直接认作产品冗余。下一轮分别采样单一字号/单一主题及长文本布局/高度反馈，确认成本与可见收益后再改，不能把两项正确性修复或本次观察写成已优化全部Markdown/滚动性能。

0.23.15/build46 已完成上述两项Markdown正确性修复及完整CI发现的PDF旧跨页坐标页身份修复：最终CI40870093415的664项Core、legacy/overlay严格边界、29/152项Markdown和既有全部原生回归通过，Release与本机原书验收完成。参数缩减候选未采用，后续仍按单一字号/主题拆分采样，不把本次交付当性能收益。工作区本轮清理3.05GiB可再生/重复载荷，保留唯一重放/失败/原始证据、最新15及14回滚，复跑使用共享缓存与canonical包重建。

0.23.15之后的[字号/主题与高度反馈诊断](2026-10-29-webkit-layout-results.md)已完成新12进程、独立1,064项全过，发现重复等高post却没有同值Native待写重复；单独调用栈提供SwiftUI精确字节比较的待测依据。下一轮只对两个独立最小候选做3臂36进程轻量A/B，固定CPU观测窗排除quiet提前假象，不测组合，最多采用一个；尚未改产品，不预告收益。

本轮字号/主题12诊断+36候选对照已结束，两个候选均未通过整体门槛，未进入产品；真实高度恢复/DOM/来源保真通过，冻结分析器队列时点校验失败完整记录。当前仍15/build46；详见[最终结果](2026-10-29-webkit-layout-results.md)和[六批后续顺序](2026-10-29-performance-progress.md)。先续固定指针/等待条件的PDF FPS，再分解长文WebContent实际排版与回传；不能将减少size或局部CPU节省直接当最终界面收益。
