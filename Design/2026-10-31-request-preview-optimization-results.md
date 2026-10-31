# 对话请求准备与知识库预览优化 · 0.23.30

本批承接已交付的0.23.29，落实两个经过实际Release模块对照的非PDF候选。当前产品源码、本机编译、原生知识库验收、GitHub完整CI、发布、安装和原书两次启动验收全部通过。原书、笔记、分析保留。

| 改动 | 有效对照 | 收益及边界 |
| --- | --- | --- |
| 对话完整冻结时，空的显式附件集合不再遍历整书笔记/布局节点ID | 6种情形、48个新进程、每种4对AB/BA，实际`ReadingPreparedAnswer.freeze`完整输出及错误相同 | 大书当前页空附件CPU中位−28.13%，每次省0.169ms；单笔记−11.70%、两笔记范围−23.23%。整书对照多0.0424ms，未隐去；额外峰值RSS最高176KiB。不是模型、文件读取或整App提速。 |
| 知识库无搜索的长分析折叠预览，只规范化足够显示120字的前缀 | 实际public Release Core跨模块24进程、每进程2424项Unicode对照；另8进程较小中文样本 | 8条每条432012字节的压力样本，局部准备省31.44ms；较小中文样本省1.01ms。短文和非空搜索保留完整旧路径；不是SwiftUI整帧/FPS收益。 |

第一版短预览在短文本上多0.0075ms，保留原结果并改为4096字节以内走完整旧路径。整书来源索引在8/32可见行分别多314.25%/9.92%局部CPU，因此否决，没有整合进产品。没有把先前已经存在的按需读取或共享冻结重复算成新优化。

`ReadingQuery.swift`保留非空附件的成员、重复、上限、回收及书/来源权限检查；每次读取当前项目，没有跨请求缓存。`ReadingKnowledgeExcerpt.swift`按Unicode标量去掉首尾空白后读取完整字素前缀，并留一个字素处理换行替换可能连接的尾部；原始Markdown和完整搜索内容保持。新增5项`RequestPreviewTests`覆盖长文、CRLF、NFD、emoji、组合标记、阈值、全文末尾搜索及空/非法/变化附件。

本机只有Command Line Tools，5项本机检查是对实际public Release Core运行相同测试源码和断言，不冒称XCTest。完整XCTest已在最终GitHub CI执行并通过。

原生检查链接当前真正的AppStore/Core/KnowledgeLibraryView；基线为0.23.29产品源ce2d624b607dc084952954c1a1750e580425592f。同一本合成书8条预览的完整AX描述与基线一致，末尾独有词命中1条，最后记录可达，跨书清空搜索。顺便修正分类按钮被父级统一成同一个无障碍名称的问题：笔记/分析/要素各有独立名称和悬停说明。

首次候选fixture按最近更新时间载入书44、基线选书43，数组顺序也不同；保留差异调查并显式重选43复核。每本合成项目按ID核对完整字段相同；这不是产品数据变化。原库21文件及全部生产偏好在隔离验收后保持；没有真实模型请求。

证据入口：`logs/request-preview-20261031/current-source-ui.json`、`product-integration-v1.json`、`delivery/delivery-plan.json`；完整对照在`logs/conversation-workspace-20261031/next-performance/`的`formal-v1`、`excerpt-public-core-formal`、`excerpt-typical-confirmation`。每次安装前重新保护当时的原库、偏好和上一安装App，不用历史备份覆盖当前数据。

本批继续遵循用户界面偏好：明确的细节直接精修，需要有实质取舍时再展示设计方案；不恢复已退役数学核查。后续16类组件轮转应优先找真实工作入口的重复准备和跨组件传递成本，保留不利样本，确认收益后再改。

## 最终交付与清理

产品源 `f20862f50fdcc917b0a1efde952537d1ba3746a8`，[完整CI41202619431](https://github.com/theincrediblewwz/readingbook/actions/runs/41202619431) 的758项Core测试、101项具名回归、15项实际渲染器检查和全部既有原生门槛通过，零编译警告。本批没有失败重跑。[0.23.30/build61](https://github.com/theincrediblewwz/readingbook/releases/tag/v0.23.30) 已发布并替换本机安装；实际About确认30/61。artifact13043871874、Release429945436，双架构、严格签名、32资源/36程序文件、远端资产digest均已核验。canonical `dist/ReadingBook-0.23.30-Mac.zip` 为26037217字节、SHA256 `edee083df4935c3d47e1327872f48c33a0f4449cb9fc12690206da6946aeefae`。

安装实际PID82321/82388：原书104/1484页、343%、102页旧句译、已有问答、收起入口、对话工具、回到原文、书库顶部重选、组件目录、正常退出重启及空草稿全部核对。两个实际PID的三类原生运行警告均为零。最终清理后，21个原库文件集合及全部字节、所有生产偏好完全保持，当前36程序文件与CI相同；未提交进度文档SHA保持。最新21文件/偏好及29回滚App在 `private-books/request-preview-20261031/install-before-0.23.30/`。没有生成AI、新增组件或保存原书新笔记。最终入口 `logs/request-preview-20261031/delivery/final-delivery.json`。

唯一回放包 `logs/request-preview-20261031/replay-evidence.zip` 为184451200字节，SHA256 `fe7a1c9d20d939521bc5a7e2c1eb3826c22feb54562e8916c65e71792b843927`；1212路径/560去重块及实际恢复程序执行权限均核验。29/30实际程序、失败/否决候选、完整输入/输出、源快照、编译flags、真实产品UI helper与合成库保留。对象、dSYM、结束的helper目录及重复展开的完整capture退役；需要时先读该批 `REPLAY_AND_RETIRED.md` 并按窄前缀恢复。

另清理五份旧generated-trees回放中可重建的二进制/编译模块，全部非二进制源码、输入、原始结果和日志保留到各原目录的validation-inputs.zip，原manifest和审计身份保留；旧完整程序恢复命令已退役，先读BINARY_RETIREMENT.md。最新和上一版canonical包、29 App回滚、所有非App私人保护及关键证据保留。旧28App、旧/重复ZIP和远端28Release/tag/Actions程序产物精确退役；GitHub保留30/29、main提交历史和必要失败诊断。

四个清理阶段观察到约3.07GiB减少；全批6862056→4343192KiB（约6.54→4.14GiB），净减少2518864KiB（约2.40GiB），阶段删除量和全批净变化分别报告。仍保留活跃mac-debug和共享编译缓存。final-preservation-check逐项重核数据/程序/回滚/ZIP；下一轮只读线索见该批next-components-audit，包括摘要目录256文件边界、文件夹树和跨组件更新。摘要边界尚待复现。
