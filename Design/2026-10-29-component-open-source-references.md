# 阅读组件与组合机制：一手资料核查

核查日期：2026-10-29（Asia/Shanghai）。范围是为 ReadingBook 的组件内部、组件通信与组合寻找可局部借鉴的策略；**没有跨产品同机 benchmark，不作“更快/更省内存”排名，不建议替换整套阅读引擎**。GitHub 项目优先通过已连接的 GitHub API 读取默认分支的 README、许可证与指定小文件；Apple/Skim 读取官方页面。未 clone、下载源码树/安装包/大资源，未启动 GUI、编译或测试，也未引入依赖。

当前项目边界：macOS 15+，SwiftUI/AppKit/PDFKit 与 WKWebView，已内置 markdown-it；真实原书、Markdown、分析及锚点版本是保留对象。下表“借鉴”列是适配建议，不是已实现或已证明的提速。

| 一手参考／许可证 | 已核架构与格式 | 可借鉴的具体策略 → 本项目落点 | 适配边界／待核 |
|---|---|---|---|
| **Apple PDFKit + SwiftUI 官方文档**；Apple SDK，非开源实现。[PDFView](https://developer.apple.com/documentation/pdfkit/pdfview)、[可见页通知](https://developer.apple.com/documentation/pdfkit/pdfviewvisiblepageschangednotification)、[WWDC23 性能](https://developer.apple.com/videos/play/wwdc2023/10160/) | PDF 原生视图、导航、选择和通知；SwiftUI 官方建议缩小依赖、移出 body 内昂贵计算、保持稳定身份。 | **内部/通信优先**：区分视口变化、语义页变与持久保存；只让确实显示进度的视图依赖高频状态。PDF 宿主配置差异更新与整体布局分开审查。 | API 已核；不把可见页通知当作逐像素滚动回调。新旧回归原因仍需本机逐项实测，文档不是现有卡顿的归因证据。 |
| **Skim**，macOS PDF 阅读/笔记应用；官方项目页标注 [BSD](https://sourceforge.net/projects/skim-app/)。[官网](https://skim-app.sourceforge.io/)、[官方更新记录](https://skim-app.sourceforge.io/relnotes.html)、[源入口](https://skim-app.sourceforge.io/developers.html) | 原生 Mac PDF 应用，官方记录包含 PDFKit 兼容修复；PDF、注释、快照、缩略图与链接预览。 | **内部**：1.7.10 将 tooltip、snapshot 缩略图和演示绘制异步化；1.7.15 避免 live resize 自动测量笔记行；1.7.7 避免笔记变化引发无谓重绘。适合对照悬停预览/笔记/缩略图生命周期。 | 功能、策略与 BSD 类别已核；官方指向 SVN，源码浏览受阻，未核到具体实现和逐文件许可，不能直接搬代码。 |
| **Readium Swift Toolkit**，[BSD-3-Clause](https://github.com/readium/swift-toolkit/blob/develop/LICENSE)。[README/格式表](https://github.com/readium/swift-toolkit/blob/develop/README.md)、[Navigator](https://github.com/readium/swift-toolkit/blob/develop/docs/Guides/Navigator/Navigator.md)、[Package](https://github.com/readium/swift-toolkit/blob/develop/Package.swift) | Publication/Streamer 与 Navigator 分层；EPUB、PDF、CBZ、音频；Navigator 不负责永久存储，位置经 delegate/Locator 交给宿主。 | **通信/组合**：借鉴统一导航、选择、装饰协议与可序列化位置契约；界面层提供工具栏，宿主负责保存。可用于梳理 PDF/文本组件共同接口。 | 当前 develop 明确 iOS 15、UIKit、Swift 6.2，**不是原生 macOS 即插即用组件**；不能用 Locator 替掉本项目的精确字节/UTF16/原文版本锚点。 |
| **Sioyek**，[GPLv3](https://github.com/ahrm/sioyek/blob/development/LICENSE)。[README](https://github.com/ahrm/sioyek/blob/development/README.md)、[渲染器头文件](https://github.com/ahrm/sioyek/blob/development/pdf_viewer/pdf_renderer.h) | Qt/MuPDF 的 PDF 阅读器，支持 Mac；渲染/搜索请求分离，worker 与搜索线程、缓存响应、完成信号独立。 | **内部/通信**：渲染请求显式带文档、页、缩放、屏幕 scale、分片与注释状态；工作线程拥有自己的 MuPDF context。可借鉴缓存键完整性、结果失效与任务所有权。Portals 可供“原文+参照”交互参考。 | 不照搬线程数、缓存页数或 MuPDF 上下文规则到 PDFKit；仅参考设计，实际代码复用先审许可证/依赖。未做同机性能比较。 |
| **Readest**，[AGPLv3](https://github.com/readest/readest/blob/main/LICENSE)。[README](https://github.com/readest/readest/blob/main/README.md)、[进度 store](https://github.com/readest/readest/blob/main/apps/readest-app/src/store/readerProgressStore.ts)、[联读组](https://github.com/readest/readest/blob/main/apps/readest-app/src/store/parallelViewStore.ts) | Next.js/Tauri + FoliateView；README 列 EPUB、PDF、MOBI/AZW3、FB2、CBZ、TXT、HTML、MD。进度按 book-view key 独立 store；联读组独立维护。 | **通信/组合最相关**：高频进度从通用 readerStore 拆出，只按当前书视图订阅；事件处理可读取而不订阅；关闭释放；联读只共享显式组。可映射本项目的进度/选择/时间组与组件生命周期。 | 源中 Android/React 性能描述不等于本机 Mac 证据；Zustand 写法不能机械翻译为 SwiftUI。架构参考，未复制 AGPL 实现或推荐换 Web 引擎。 |
| **markdown-it**，[MIT](https://github.com/markdown-it/markdown-it/blob/master/LICENSE)。[README](https://github.com/markdown-it/markdown-it/blob/master/README.md)、[架构](https://github.com/markdown-it/markdown-it/blob/master/docs/architecture.md) | CommonMark 与扩展；core/block/inline 规则链生成 **token stream**，再由独立 renderer 输出 HTML；本项目已内置。 | **内部/组合**：区分源解析、token 结果与渲染快照，规则和 renderer 分责；可检查同一笔记是否被多组件重复解析，用源版本与配置作为缓存键。 | token 的行位置不等于精确字节/UTF16 锚点；不改原 Markdown。最新默认分支已使用 TS，不能据此直接升级现有 vendor 或放开任意插件。 |
| **GRDB.swift**，[MIT](https://github.com/groue/GRDB.swift/blob/master/LICENSE)。[要求/并发](https://github.com/groue/GRDB.swift/blob/master/README.md)、[查询与观察区域](https://github.com/groue/GRDB.swift/blob/master/Documentation/QueryInterfaceOrganization.md) | Swift SQLite 工具，官方列 macOS 10.15+、Swift 6.1+；支持并发读写与基于数据库区域的观察；**非书籍格式引擎**。 | **索引/通信候选**：参考按查询/行列区域失效、共享读取与事务后通知，避免“任意保存→所有组件刷新”。若将来需要搜索缓存，可另行评估可重建索引，原项目/笔记继续保留。 | 任意筛选不保证精确到结果行，观察仍可能重复通知；不为优化而迁移真实书库，未引入 SQLite/GRDB，也未测试本项目收益。 |

建议并入组件计划的顺序（均未实施）：先明确“临时视口/进度、语义选择/当前页、持久原文与分析”三层状态；再给通信补齐 library/book/source-version、origin 与任务代次，组合页仅转发选择/时间组，防回环与旧库结果串入；最后对有证据的单个组件做有限缓存、取消和失效。每次只改一个责任边界，保留相同 fixture 的启动、交互、内容 FPS 与内存对照，不能用开源项目介绍替代本机验收。

已核：上述 README、五份 GitHub LICENSE、Readium Package/Navigator、Sioyek 渲染器、Readest 两个 store、markdown-it 架构、GRDB 查询观察文档、Apple WWDC 与 Skim 官方记录。待核：Skim 具体源码/完整逐文件许可；所有候选的本项目集成成本与真实收益。当前没有“性能领先”结论或新增依赖建议。


## 2026-10-30补查：生命周期与取消

本批等待完整CI期间，在线复核了一手资料；只借鉴局部设计，没有下载新引擎或增加依赖。

- [WebKit的能耗建议](https://webkit.org/blog/8970/how-web-content-can-affect-power-usage/)建议合并定时工作，并说明不可见页面会停止rAF、降低优先级。与本项目本批的有界合并方向相符；但原生WK、浏览器标签和SwiftUI透明视图不等同，不能据文档认定`isHidden`安全，也不能把120/250ms写成系统完成保证。
- [Foliate-js的书接口](https://github.com/johnfactotum/foliate-js/blob/main/README.md#the-main-interface-for-books)显式区分章节load/unload；图片和资源按需加载。可借鉴“资源生命周期跟随章节”的思路。其PDF适配被项目标作实验性，且长文分页仍有性能限制，没有依据建议替换本项目PDFKit。
- [Readium最新迁移说明](https://github.com/readium/swift-toolkit/blob/develop/docs/Migration%20Guide.md#swift-6-and-strict-concurrency)要求资源流协作取消、隔离可变句柄；CPU重任务需明确离开UI actor。文档中4.0 alpha的要求不等于本项目应升级Swift或直接引入UIKit导航器。

再对照当前代码，已有能力必须先扣除：PDF悬浮有hit-band索引和阅读空闲调度，几何缓存已有16页/12MiB的闲置目标（可见页允许超出），原生准备由独立actor拥有PDF，逐请求校验并协作取消；这些不是下一轮待补功能。256条/1MiB的单页引文缓存满时全清，是可观察候选，但普通场景未证实触顶，先不为它改LRU。

下一轮优先查两条实际链：快速切页后旧准备任务是否及时结束并释放；悬浮密集来源时准备、命中和发布分别占多少。保留无装饰/稀疏/密集、同页命中/跨页返回和取消对照，先排除已有索引和缓存的作用，再决定是否改页内任务分组或失效粒度。门槛仍看整条用户动作与原数据/迟到结果守护，不凭内部调用计数宣称收益。其他16类和四条跨组件任务继续沿用原计划。
