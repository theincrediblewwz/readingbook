# Markdown/WebKit：字号、主题与高度反馈

当前产品0.23.15/build46，源码5b0d4a1；共同实验源码为main f0460ff（产品代码一致）。分变量诊断和轻量A/B均已完成；两个候选均未通过采用门槛，未修改产品，不新增版本或替换相同应用。

## 已完成的分变量诊断

一个非testable Release诊断二进制，合成20KiB/512KiB × font-only/theme-only ×3全新进程，共12行；两个正确性preflight在冻结后运行但不入矩阵。每进程initial、single-step、reset、24次/50ms burst分列；同进程阶段不算独立样本。font只变字号、主题固定light，theme只变明暗、字号固定18。保留完整presentation桥接参数，没有恢复上轮参数裁剪。

正式数据前冻结源码、二进制/资源、输入、工具与独立分析器；最终二进制e18816148121731767f2998fb14ee2449af83c9e6829f008c4f52b0b57168eb5，计划853ec931688ff70133b83d64cd6bee28fb93730bbcc1efcbfc153b6c133915cf，分析器d3c7f11e5c697c8e6a51102080dd2f09804e33ed148d1240f42f306d32460825。12行退出、前台、选区/HTML/源码精确字节、Native UTF16、真实几何和来源均通过，独立1,064/1,064检查通过；stderr/精确12PID统一日志的原3类警告及另列constraints为0，编译警告0。所有原始失败和未执行的准备构建版本保留，不与正式数据混用。

稳定观察复用产品既有rect样本，不逐帧另做几何读取；State轮询读取原有比较的缓存结果，不额外扫描整文。诊断size消息含小型metadata且逐阶段有完整trace，存在额外成本；数据只用于定位，不直接算生产优化收益。纯theme末态允许已显示状态复用，不强迫第24输入新派发。原guard无在途/当前State/样式/JS证据与真实frame才可完成；120ms quiet是完整性围栏，不当作用户可见延迟。

| burst-24场景 | 三行实际派发 | 三行size post | 三行等高post | 三行实际Binding写入 |
| --- | --- | --- | --- | --- |
| 20KiB 字号 | 24/24/24 | 48/48/48 | 24/24/24 | 24/24/24 |
| 20KiB 主题 | 24/24/24 | 24/24/24 | 24/24/24 | 0/0/0 |
| 512KiB 字号 | 12/10/12 | 8/7/9 | 4/1/4 | 4/6/5 |
| 512KiB 主题 | 14/14/14 | 6/6/6 | 6/6/6 | 0/0/0 |

single+burst两测量phase合计276条size，183被Native epsilon过滤，93 queue/93 commit，非法0、同值重复待写0。因此有严格等高post去重的行为依据，**没有Native待写合并的样本依据**。主题无height写/实际bounds变化，却仍有每burst24次WK.layout，不能把这些调用都归因高度反馈或当作WebContent布局CPU。

276次产品几何查询有272次记录0ms，其余1/1/1/3ms，分辨率不足，不证明免费或主瓶颈。长文call→completion约73–170ms的未解释区间涉及跨进程执行/调度/交付，不能直接叫序列化或排版耗时。WebContent资源未归属测量，没有FPS/首像素/系统总内存结论。

本机原始证据在logs/webkit-layout-20261029/experiment与independent-analysis-01.json、independent-diagnostic-findings-01.md。全trace诊断App已保留唯一12.1MB重放ZIP，之后重用同一源码/build/App，不逐行复制。

## 单独调用栈与候选依据

另一个同二进制长文theme进程采3秒/1ms原生调用栈，明确排除正式12行及任何收益比较。采样时间覆盖晚期setup/single/burst混合，不能把样本计数当单phase成本百分比。多个SwiftUI布局比较支路出现MarkdownDocumentBytes.==→Sequence.elementsEqual，提供了检查精确字节比较实现的定性依据；不是凭此宣布根因已定。

初诊后提出两种互相独立的候选：

1. 保留原RAF/rect/RO/resize/字体/图片调度，只在同document revision与ceil整数height严格相同时跳过重复post；新revision首条照发。不用epsilon或全局seen集合去重，不合并Native队列。
2. 仅对MarkdownDocumentBytes的精确UTF8比较使用公开连续缓冲区：同地址/等长度可直接确认；其他情况精确比较所有字节；无连续存储回退原elementsEqual。不使用String规范等价、不构造Data/hash/整篇数组、不持久缓存指针、不改State/授权和源文保存语义。

公开API已核本机构建SDK的String.UTF8View.withContiguousStorageIfAvailable；非mutating，foreign存储可返回nil。原始API证据与路径/SHA保存在utf8-buffer-api-verification.json，产品不能调用SDK内部_guts实现。

随后按3臂(control/height去重/byte-fast)×两操作×两规模×3正式执行36新进程，控制与两个候选同一Release二进制，分别比较，共用control，不测组合，至多采用一个。轻工具去掉重trace/size metadata；size仍为原height/revision字段。拟以single固定1s、burst固定3s观察窗的主进程CPU为主，截止前必须实际语义/几何完成；quiet只核完整性，不将更早停止围栏当提速。具体门槛与分析器在正式数据前独立冻结，最终结果见下文。

## 正式36进程对照：两个候选均不采用

最终Release二进制`54b9ddd051a4cc1e69fdbd22e0839a426d03de3836528153681a1381f73f1374`，计划`045a50fba384118f2b2747087fc8006d6010dd68c7a9513a67c773d44953c2e6`；独立分析器`4f91e38bd217d5417a10bc0410147d13f95dbfcebc3a39276ee4ab451af174a0`。控制/等高post/byte-fast同一binary，两个候选分别对同一control，未测试或采用组合。3臂×两操作×两规模×3全新进程，36行全部保留、无重跑/删行/替换；前台、程序断言、原始DOM/Range/选区、Native UTF16、公式/图片/链接、原文和完整保存全部通过。固定single1s/burst3s后台自进程CPU窗，最大截止偏差约1.077ms，小于预定10ms。未归属WebContent/GPU，不能据此称FPS、首像素或整机内存收益。

正式前的三个真实Native高度正控均通过：同一WK由实际Binding40/viewport resize恢复10227；100→101→100每步发送；同外部revision full render、新revision、新WebView首报保留。真实helper625检查通过，实际two-field wrapper和State/revision/授权边界另经审查。随后两正常路径预检通过。锁屏使更早的一个正常预检在foreground阶段超时，该失败完整保留；用户手动解锁后的两预检是独立前置正确性检查，不与正式36行性能数据合并，没有改变锁屏设置。

下面都是这轮合成工作负载的**配对CPU节省比例中位数**，正值省CPU、负值增加CPU；它不一定等于两个非配对中位数之差。表内百分比仅为描述，两个候选的全套采用资格均失败。

| burst24场景 | 等高post候选：CPU节省 | byte-fast：CPU节省 | byte-fast末次输入到语义/实际frame稳定的配对延迟变化中位数 |
| --- | ---: | ---: | ---: |
| 20KiB 字号 | +1.67% | +7.73% | −2.85ms |
| 20KiB 主题 | −5.15% | −8.16% | +0.64ms |
| 512KiB 字号 | −9.27% | +22.57% | +340.35ms |
| 512KiB 主题 | −1.87% | +43.76% | +35.51ms |

- **等高post不采用。** 它确实让20KiB主题burst的24条size变为0条，但CPU/响应没有稳定改善，全部12对burst的CPU净变化为增加0.204883秒；多个single/burst回退门槛失败。20KiB字号的48条仍照发，因为真实height/viewport resize保真路径不能被省略。少发IPC不自动等于更流畅。
- **byte-fast不采用。** 它在三个cell的CPU正向门槛通过，全部12对burst合计省0.716134秒；但20KiB主题CPU回退、512KiB字号及主题最终语义/实际frame响应回退，single的若干延迟/队列门槛也失败。不能只报告较好的CPU数字而把这些代价交付给用户。
- 原3类运行警告与constraints均0，编译警告0。原库20文件和已安装15应用36文件逐字节不变，全部偏好也不变；未发模型请求。

### 分析工具的已知失败，完整保留

冻结分析器共3,799检查，3,727通过、72失败；**72项全是两个phase×36行的`queueClock`元数据一致性校验**。driver先算队列lag，再在foreground函数检查NSApp/窗口状态并记录`Fore.ticks`，两个时点之间有开销；分析器把两者要求为近乎逐纳秒一致是不成立的。没有修改冻结脚本、放宽阈值或删除失败，正式完整性资格因此为false。

主CPU来自独立后台raw rusage/时间窗，真实语义延迟由原始输入/完成tick复算；不依赖该冗余lag字段。作为补充描述可定位这些独立数值，但不能把整轮称为“所有性能验收通过”。即使只看预先规定的CPU与语义延迟，两候选也各自未通过数值门槛，因此修正这项工具一致性问题不会使本轮可以采用候选；不补跑较好样本来改变结论。下一次涉及主队列指标前应先统一记录时点，并做独立时钟合同检查，再重新冻结新实验。

## 当前交付和下一步

此次只同步测试结论、性能进度和接续说明到main；产品仍为已核验的0.23.15/build46，原有两项已交付性能收益继续保留。不发无变化的新版本，不安装诊断程序。最终AB重放包12,185,476字节，SHA256`ac807e3475ebd82614ae395ff2d1ca52275f59cef6bfe9c5745c834f5f0ac3df`，与全部35个App文件的内容/权限及CRC核验通过。

本轮四个场景没有证实高度通知去重的收益；字节比较是局部CPU成本，但仍未解决长文排版/回传的响应路径。下一轮优先按[六批顺序](2026-10-29-performance-progress.md)回到严格条件下的PDF滚动FPS；之后再把长文Native提交、WebContent执行/布局与回传分别归属，不能把整段往返时间直接叫作WebKit布局成本。保持单变量、原书/笔记/分析保留、共享工作区缓存和精确清理清单。

收尾校验：原App实际About仍15/build46，原书103页/343%与伴读/对话切换通过；原书/笔记/分析字节不变，只正常更新Workspace/主窗口几何。工作区观察值6,833,388→6,215,244KiB（约5.93GiB），减少603.66MiB；开工6,133,424KiB，必要紧凑证据与保护资料净增约79.90MiB。302,349,991字节的大型原始DOM/owned-PID日志经逐项SHA/CRC核验无损压为10,375,466字节，恢复脚本pack-raw-evidence.py及清单保留；App/source/build已退役，两个不同二进制各保留一份可重放ZIP。
