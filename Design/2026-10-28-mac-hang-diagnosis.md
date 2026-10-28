# 0.23.9 · 伴读菜单布局循环的确定复现与修复

## 结论与源码

本轮已把卡顿收窄到伴读工具栏的双候选 `ViewThatFits`。宽度、隐藏和折叠变化时，原生菜单候选子树在测量中反复构造，主线程一直弄脏布局。正式负对照停在第 40 步，记录 6,898 次原生标记构造，并出现与用户现场相同的 `300 iterations` 警告。

只把伴读工具栏换成 `ReadingAdaptiveRows`：同一套菜单保留身份，布局仅决定一行或两行的位置；聊天及纯按钮的 `ViewThatFits` 保留。窄窗、字号和既有菜单动作仍走原实现。PDF hover 通知的异步 FIFO 修复一并保留。没有改动书籍存储格式、原书、笔记或分析，也没有发起付费模型请求。

## 前后对照

- 最小原生回归：真实 `ReadingAdaptiveRows` 的玻璃/不透明两种场景均完成 100 步，24 次原生标记构造、12 次拆除，无布局或发布期警告；仅保留旧伴读工具栏的负对照仍卡住。脚本为 `scripts/ui-layout-regression/run.py`，旧结构只在主动传入 `--baseline` 时运行。
- 真实产品对象回归：直接链接 AppStore、ReaderFloatingPanel、ReaderAIPanel 和 WorkspaceView。未修版本在第一次打开伴读便断主线程心跳并出现 300 轮布局；修复版浮窗和完整工作区各 24 轮通过。
- 同一 1,484 页 PDF 的书库副本：24 轮常规和 120 轮压力通过。压力组完成 720 个开关、切标签、缩窗及跳页动作，最大主队列响应延迟 1.225 秒；草稿保留，布局及发布期警告为零。此数字是主队列心跳延迟，不是帧率。
- 新增 5 项 Core 几何测试；实际几何源码的 1,230 组确定性探针、17 项悬停交付边界检查通过。本机缺 XCTest，完整 Core 由 GitHub 的 Xcode 环境验证；本条不是完整 Core 通过声明。

本机证据位于 `logs/ui-layout-regression/`、`logs/native-ui-harness-20261028-125318-fixed-pdf-stress/` 和 `logs/mac-release-20261028/`，全部忽略提交。用于构建的版本为 0.23.9/build40；完整 Core、双架构 Release、包校验和实际安装核验尚在后续交付流程中。

旧安装版、原书库和偏好已备份到本项目 `private-books/mac-release-20261028/`；只在测试副本验证。以下为同一天前两轮的历史记录，不能把其中“未确认”当成当前复现状态。

---

# 0.23.8 Mac 卡顿调查：已抓到布局循环，局部修复已验证

## 12:20 现场与局部修复

用户再次报告卡住并自行采样，确认触发动作是刚打开“伴读与对话”。用户采样 `logs/mac-sample-20261028-122024.0GbOtU/` 与补采样 `logs/mac-sample-20261028-122103.14MW9j/` 属于同一 0.23.8/build39 进程。现场持久偏好记录第 182 页、343% 缩放，不能单凭偏好还原卡住时每个控件状态。

| 时间 | 主线程样本 | NSWindow 布局样本 | NSHostingView 布局样本 | footprint |
| --- | ---: | ---: | ---: | ---: |
| 12:20:24 | 869 | 761 | 735 | 686.7 MiB |
| 12:21:03 | 894 | 788 | 778 | 960.4 MiB |

CPU 约 91–100%。主链为 `NSApplication.run → CA::Transaction::commit → NSWindow.layoutIfNeeded → NSHostingView.layout → GraphHost.flushTransactions → GeometryReader / sizeThatFits / explicitAlignment`。后台线程基本等待，无持续 PDF 文字提取/目录读取或主线程 PDFKit 锁等待热点，也没有上午明显的 AX 层级枚举。

系统日志在 12:20:19 明确报告窗口布局因布局/约束一直被弄脏，已连续进行 **300 iterations**；12:18:17 和 12:19:53 各有两条 `Publishing changes from within view updates`。已确认主线程持续布局；采样深度上限和内存增长本身不证明无限递归或内存泄漏。

只修改 `PDFReaderView.swift` 的悬停通知边界。确定可达的违规链为 `make/updateNSView → update(from:) → load → clearSourceDecorations → onSourceDecorationHover(nil) → ReaderInlineState.leave → @Published`。四个出口统一在主队列下一轮按 FIFO 交付；有效命中核文档、导航、交互代际和当前 hover 身份，阻挡/安装期丢弃旧命中；空 reset 仍能跨重载清理旧卡。原书、笔记、分析、存储格式及付费请求行为未改。

- Debug 基线与修复版均构建成功。相同书库副本的基线启动有 **2** 次发布期警告，修复版启动、打开伴读、切对话、收起/恢复和重新导入后为 **0**，对应 unified 日志在 `logs/mac-hang-20261028/`。
- 修复版正文/末页跳转及未发送草稿保留已在 UI 核对。同一 PDF 在测试副本重新导入，跳到第 182 页首次打开伴读完成显示，CPU 回到 0.0%；采样另存 `patched-cold-open-companion.sample.txt`。没有发起 AI 请求。
- 从产品方法原文提取的 Foundation 主队列探针 **17 项通过、0 失败**，覆盖非同步交付、FIFO、切文档/导航/交互丢弃、reset、callback 移除和宿主释放。证据为 `hover-delivery-probe-result.txt` 和源码摘要记录；不替代 AppKit 或完整 Core 回归。
- `swift test` 已尝试，但本机只有 Command Line Tools、没有 XCTest，报 `no such module 'XCTest'`；未宣称 584 项 Core 通过，完整回归仍需有 Xcode 的环境。
- 最小 UI probe 对实际 `FrostWindowAppearance` 启用/禁用各做 100 次状态更新，两者均正常。未据此修改窗口外观；`ViewThatFits`/原生 Menu 组合仍是待验证候选。
- **未修改源码的 Debug 基线也未复现整段持续卡顿。因此目前只确认消除了违规发布，尚未证明它足以根治现场布局循环。** 原安装包未替换，源码未提交或推送。

源码、构建、诊断和书库副本均留在项目内，原始日志不进入 Git。测试应用使用独立身份和项目内书库，避免改写用户原库。

本轮结束已退出诊断应用，并把它在系统标准位置生成的临时偏好和保存窗口状态收集回 `.build/diagnostic-home/collected-os-state/`；未遗留诊断进程。采样工具新增同进程最近五分钟系统日志，已实跑验证，仍只写本项目 `logs/`。

## 上午对照（历史记录）

2026-10-28，从 `codex/reader-audit-after-0.23.8` 接手。工作目录原先为空，拉取后工作树干净；没有覆盖本地源码改动。已按 `MAC_TEST_CHECKLIST.md` 顶部先采样再判断。

- 环境：MacBook Air / Apple M5 / 16 GB，macOS 26.5.2；已安装应用 0.23.8/build39。未重新构建或替换安装包。
- 书籍：用户本机当前 PDF，1,484 页。初始阅读位置第 8 页，缩放 343%。原书库和偏好已备份到本工作区的 Git 忽略目录；后续进程通过命令行 `-library.root.path.v1` 使用工作区测试副本，没有更改原书库路径设置。
- 对照：已有书库副本打开伴读，正常显示既有句译；同 PDF 在空测试书库重新导入后，于第 1 页打开伴读，也完成显示。用户随后反馈当前自己操作也恢复正常。这没有覆盖所有正文页、快速翻页或导入后极短时序，不能判定问题解决。
- 已取得初始状态、已有书库打开伴读、重新导入/打开伴读过程和用户当前操作的多份 8–10 秒原始进程采样。没有捕捉到用户描述的持续三四十秒未响应状态。
- 已有库样本主线程共 1,729 次，1,379 次（79.8%）在正常事件等待；冷导入样本共 1,750 次，1,529 次（87.4%）在正常事件等待。主要路径为 `NSApplication.run → __CFRunLoopServiceMachPort → mach_msg2_trap`，不是死锁证据。
- 两份样本分别有 257 / 111 次辅助功能层级枚举；冷导入样本包含 `PDFAccessibilityNodePage.accessibilityChildren → CGPDFPageCopyRootTaggedNode → PageLayout::getWordsInLine → CoreNLP`。这由自动化观察引发，不能当作伴读根因。初始 AX 列表还列出隐藏、禁用的伴读控件，截图确认初始面板未展开，不能把它们解释成准备任务停滞。
- 采样是聚合分布，不能给出最长单次停顿，也不能证明点击边界的所有瞬间均被覆盖。首份采样 footprint 393.8 MiB（该进程峰值 611.3 MiB）；冷导入采样 415.7 MiB（峰值 549.2 MiB）；用户当前操作一刻 `ps` 为 0.0% CPU / RSS 260,144 KiB。这些不是卡住时的资源数据。
- 只读审查的当前页伴读投影、原书目录读取及原生准备路径，没有与当前采样共同确证的新根因。没有据此修改 App、存储格式、原书、笔记、分析或模型配置；没有发起真实 AI 请求。

原始证据保存在 `logs/mac-hang-20261028/`，书库副本在 `private-books/mac-hang-20261028/`；均由 Git 忽略，只留本机。没有在项目外创建源码、构建目录或诊断文件；本轮没有构建产物。

结束前逐文件 SHA-256 核对原书库与备份一致（排除 Finder 的 `.DS_Store`）。已退出测试实例，恢复原选中书籍及原版应用；当前启动命令无测试库覆盖参数，持久书库路径仍为用户原路径。已清除本轮新导入测试书的临时位置/对话偏好。采样脚本实跑完成，并用四份本机采样验证两种主线程头均可提取，非空且只含主线程；Shell 语法和补丁空白检查通过。应用功能无改动，因此没有重跑 Core 测试或生成新安装包。

下次卡住时，保留进程，立即双击项目根目录 `采集卡顿.command`，或在项目目录执行 `bash scripts/sample-macos-hang.sh`。工具读取进程栈及 CPU/内存约 10 秒，不操作 UI、不读取书库、不退出进程，结果在项目 `logs/mac-sample-*` 下。先保留卡住时的栈，再讨论修复；当前仍保持问题未解决的状态。
