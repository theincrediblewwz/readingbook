# 工作区产物清理

用户要求源码、构建、测试、报告和备份都留在本工作目录；每轮结束清掉不用的产物，避免持续增长。清理时保留原书、笔记、分析、原库快照和安装回滚包。

先预览，不会删除：

```sh
python3 scripts/clean-workspace.py
python3 scripts/clean-workspace.py --legacy-artifacts
```

审核 `logs/workspace-cleanup/<UTC时间戳>/report.json` 后，才显式执行：

```sh
python3 scripts/clean-workspace.py --apply
python3 scripts/clean-workspace.py --apply --legacy-artifacts
```

默认范围只包括脚本列出的 helper 模块缓存，以及 `.build/ui-layout-regression/run-*/cache`。不扫描其他名字像缓存的目录，也不清共享模块缓存。缓存按需重建；helper 二进制、manifest、dSYM 仍保留。

`--legacy-artifacts` 是一次性历史白名单，限定 2026-10-28 已弃用的 `local-release`、旧缩略图诊断与旧 FPS 基线的 SwiftPM `build`，以及代码明确列出的已结束测试。它不代表未来的 Release 构建均可删除。原生测试只清复制的 app/隔离 library；性能测试只清复制的 library/input。**不删除整个 runs**，保留原始 events、system.log、采样、控制记录和 OS 状态。缺少结束报告或所属路径不符的测试会跳过。

每次运行都在工作区 `logs/workspace-cleanup/` 新建报告，列出绝对路径、分配字节数、理由、跳过项及删除结果。测试副本另存每文件 SHA-256、文件模式与符号链接元数据；可重建缓存不逐文件哈希。分配字节是估算，APFS 共享块使实际释放空间可能不同。报告不是书库内容备份，不能用于恢复已删测试副本。

脚本不接受任意删除路径；拒绝符号链接目标/祖先、越出工作区的内部链接及特殊文件。执行删除前及每个目标前检查活跃 Swift/Clang/链接器、ReadingBook、原生测试和采集进程，再核对目标未变化。只对白名单内 `.build` 子目录执行删除，**不碰 `Sources`、`Tests`、`scripts`、`Design`、`logs`、`private-books`、`dist` 和 `.git`**，也保留旧性能 app/source/archive/manifest 及当前 `.build/mac-debug`。

后续 builder 应共用工作区内 `.build/shared-module-cache/swift` 和 `clang`，分别设置 Swift `-module-cache-path` 与 Clang `-fmodules-cache-path`，避免每个 helper 再存一份系统模块；临时文件、二进制和运行报告仍各自隔离。

SwiftPM 会显式指定自己的模块缓存，单设环境变量不足以覆盖。走 `swift build` 的 builder 还须通过 `-Xswiftc -module-cache-path -Xswiftc <共享目录>` 和 `-Xcc -fmodules-cache-path=<共享目录>` 传递参数；构建 manifest 保留该轮实际参数，不能事后改写旧构建记录。
