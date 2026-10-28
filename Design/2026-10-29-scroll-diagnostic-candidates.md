# PDF 滚动诊断候选与历史条件边界（2026-10-29）

**状态：候选待测，本轮未实施。** 三开关诊断 App 的制作和编译计划已取消；未修改产品源码，未生成新实验 App，也未给正式安装版增加开关或计数器。`prepare.py --prepare-only` 尚未落地。先核对输入、前台、指针和悬停条件，再决定是否需要组件消融，不能仅凭原六轮较低 FPS 修改产品。

## 本轮新控制的含义

窄窗 800×632、343%、第 182 页起、同一 ROI 和程序化连续滚动下：

| 记录 | 内容更新 FPS | p95 更新间隔 | 条件与资格 |
| --- | ---: | ---: | --- |
| b164 缩略图解绑控制 `opt1029-old-thumbnails-off-narrow-control4` | 58.323 | 17.300 ms | manual gate 记录移开指针、无菜单/hover、结束人工操作；前台/跨页/日志门通过 |
| f0 清指针控制 `opt1029-f0-clean-pointer-narrow-control` | 58.903 | 17.199 ms | 相同窗口/页/缩放，manual gate 记录指针在左下百分比处、ROI 外且无 hover；718 ticks，前台/跨页/日志门通过 |
| `opt1029-old-thumbnails-off-narrow-control2` | 47.492 | 33.568 ms | **已排除**：计时中发生 Cua Raise/AX 观察，并看到 hover 卡；不是有效缩略图或单独 hover 对照 |

原始本机证据（不推送）位于 `logs/mac-refinement-20261028/scroll-fps/<记录名>/result.json`，控制 2 的排除理由在 `operator-exclusion.json`。这些是单轮诊断控制，不替代宽窄各三轮、物理触控板或其他阅读场景的验收。它们说明 f0 的低值不是在清指针条件下无条件稳定出现；不能据此断言所有性能问题已解决，或把控制 2 的差异归因于 hover 单一因素。

还有等待时间混杂：历史f0窄窗启动→滚动4.50–4.75秒，新f0控制为57.00秒（完成基本run后55.62秒），旧解绑控制约88.00秒。人工门禁延长了准备时间。因此优先固定指针和等待时间，分早期/充分等待两组；不能只按hover解释差异，也不能把新单轮当作相同早期状态的替代基线。详见[首轮完整边界](2026-10-29-scroll-control-results.md)。

## retained b164 thumbnails-off 对照已核查

[本机完整审计 JSON](../logs/mac-refinement-20261028/fps-thumbnail-ab-audit/audit.json) 保留实际二进制/TAR/补丁摘要、完整源码差异和 Mach-O 信息。该 JSON 为本机证据，不随仓库上传。

- 基线与解绑版均来自 `b164f6c2b1e4c70b393fe17705fdb11b376b12ed`（0.23.9），采用相同 `--configuration release`、`enableTesting=false`、Package.swift、arm64/minOS 15.0/SDK 26.5 和链接工具版本；两份实际二进制与 source TAR 均匹配冻结 manifest SHA。旧 scratch 已清理，未保留 verbose swiftc `-O/WMO` 命令，不能伪称本轮直接核过这些编译参数。
- 从各自原始 TAR 与冻结 Swift 源码重建的 `instrumentation.patch` 均逐字节匹配原记录。最终成功构建日志均为 `Building for production`；基线另有一次更早的失败 repair 日志，不能把它作为成功证据。
- 产品代码只差 `PDFReaderView.swift` 两处 `thumbnails.pdfView = pdfView` 改为 `nil`。另一个差异是 `PerfTrace.swift` 将 CPU 原值字段名 `*Nanoseconds` 改为 `*MachTicks`，计数器原值和定时逻辑未变；`PerfProbe.swift`、其他 Sources 文件及资源相同。
- 它是禁用**隐藏及可见**缩略图绑定的旧版诊断对照，不是 f0/cab 的功能保持式 lazy-binding 修复。不得安装为产品，也不能把旧启动加速直接当作 FPS 证据。

可复用 manifest 为 `.build/perf-harness-20261028-release/build-manifest.json` 与 `.build/perf-harness-20261028-thumbnails-off/build-manifest.json`；同目录的 App、source、TAR 与原始证据继续保留。现有 `capture-scroll-run.py --manifest <路径> --manual-setup` 可在独占窗口中复用；须用新 tag，完成截图、移开指针和无覆盖确认后再启动计时。宽窗/ROI 为 1470×843 / `500,160,750,450`；窄窗 CLI 请求 800×600、实际 800×632 / `120,130,580,350`。固定同一 fixture、343%、200 文档点/秒、60Hz 输入、12 秒及 pixelStep 6。

## 尚未实施的三开关方案

如后续证据仍需要消融，先由冻结 `cab3569c5f4c253d71d6c8f014ad9e482ef7bc68` 的归档副本制作**同一个** Release 二进制；默认全 0 作控制，每次只改一个进程环境变量。当前产品和 retained b164/f0 App **没有这些开关实现**，wrapper 转发/记录环境变量本身不代表行为已经切换。

| 候选环境变量 | 计划只改变的因素 | 必须保持 |
| --- | --- | --- |
| `READINGBOOK_DIAG_PAUSE_DOT=1` | Timeline 暂停、breath 固定 | 真实 active、颜色、help、450ms 合并及原色彩过渡 |
| `READINGBOOK_DIAG_SKIP_HIDDEN_WIDTH=1` | 面板 inactive 时停两处背景 GeometryReader preference；关闭时拒收 width | 内容仍 mounted、草稿/焦点/范围、原生 Menu 单实例及可见面板宽度测量 |
| `READINGBOOK_DIAG_BIND_HIDDEN_THUMBNAILS=1` | 文档有效时恢复隐藏 thumbnail 与 PDFView 关联 | 不改变其他 layout、显示/关闭状态、锁定文档保护或 `layoutThumbnails` 的隐藏 guard |

若制作，manifest 须写 `diagnosticOnly=true`、`formalFPSBaselineExcluded=true`，记录完整源码/补丁、flags、counter hooks 和独立 driver 指纹；不能与旧正式六轮混作同一矩阵。

## 尚未实施的计数器方案

使用非 Observable 的 MainActor 计数器，不触发 UI 发布。热路径仅整数累加或状态转换，不加入 JSON、Task 或逐帧日志：

- dot：mounted / active / effective pulseEnabled 的首末状态、转换数与区间 duty；暂停脉冲仍记录真实 active。
- 准备：仅在 `ReadingPreparationState.current` 实际发布/清除时计数。
- 原文索引：自有 viewport 通知、实际 visibleSet 变化、索引 worker 提交与实际索引发布。
- 宽度：preference 收到/改变及 frame 实际发出；区分关闭状态，以免把重复收到当作实际布局变化。

独立 driver 在实际滚动 begin/end 各发一次同进程通知；begin 重置区间，end 仅结算一条 `PerfTrace.event`，输出 counts/duty/flags。主 `ScrollDrive.m` 不改。已单独准备两通知 driver helper，去除两条通知后与原 source 字节相同；记录在 `logs/perf-optimization-20261029/driver/build-manifest.json`。**helper 编译验证不等于诊断 App 或计数器已实施**，当前没有具备上述 counter 的运行结果。

## 历史 final-f0 六轮：能证明什么

逐项只读核查 `final-f0eabf7-{wide,narrow}-run{1,2,3}`：

- 六个 `setup.json` 只有目标/driver/collector hash、输入方法、fixture 等字段；没有 pointer 位置、hover 状态或人工操作结束确认。`result.json` 有前台、原生几何跨页、位移、保全与日志门，未记录上述 pointer/hover 状态。
- 六轮 `capture/capture.json` 均为 `previewWritten=false`、`cursorCaptured=false`。后者表示不采集光标像素，**不表示鼠标位于 PDF 外或无 hover 工作**。
- 另有独立的 `final-f0eabf7-wide-preview/own-window-preview.png` 和 `final-f0eabf7-narrow-preview/own-window-preview.png`。本轮已查看，截图瞬间未见 hover 卡；这是两张设置预览，不能证明随后六个 12 秒区间都没有 hover。未采集光标，也无法据图确定鼠标位置。
- f0 冻结版 `SCROLL_FPS.md` 要求 ROI 避开 hover 卡/动画/光标，并单独做 owned-window preview；没有后来新增的停放指针和 manual gate 记录。不能把当前操作说明追溯当作旧六轮执行证明。

因此保留原六轮 48.57/47.14 FPS 及全部原始证据，把**指针/悬停条件标为未被记录确证**。现有证据不足以认定六轮全部受 hover 污染，也不足以继续把它们与等待更久的清指针控制作无条件的产品回归归因。后续如重建宽窄对照，应逐轮保存设置确认与主进程/基本run至输入的时间，并把有意 hover 工作负载与清指针对照分开；未达到同条件证据前不改产品、不宣称 FPS 已修复。
