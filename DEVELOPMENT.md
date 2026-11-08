# 开发与验证

## 默认流程：本地迭代，阶段发布

2026-11-08 起，按用户要求调整：小改动先在本机完成相关验证、编译和试用，累计成一组完整成果后再集中同步 GitHub、运行云端完整回归和发布。不要为每个小改动重复推送、打双架构包和发布正式版本；云端编译也不是本地试用的前置条件。

1. 保护当前改动和书库，在隔离资料上改代码、验证相关功能；保存本地提交，不必立即推送。
2. 用下面的本地入口增量编译。仅构建当前 Mac 架构，不打 ZIP、不访问 GitHub、不自动安装。调试布局可选 Debug；性能对照使用 Release，保持相同配置和输入。
3. 需要更新已安装程序时，先正常退出；保存最新书库、偏好、当次 `verification.json` 和上一安装程序的可核对回滚，再替换已经验证的 App。验收原书、笔记、分析和阅读位置；不恢复开工时的旧库覆盖后续阅读成果。候选目录的验证记录会随下一次构建更新，安装时保留的那份记录用于追溯。
4. 达到一组可完整演示的功能、重要稳定性改善，或用户明确要求发布时，才统一推送并运行完整云端回归，打 Universal 包、发布并核验下载。通常不为纯文案或小布局调整单独发布。

### 本地构建

```bash
python3 scripts/build-local-macos.py
# 仅在不用于性能对照的功能调试中使用：
python3 scripts/build-local-macos.py --configuration debug
```

候选程序在 `dist/local-candidate/ReadingBook.app`，记录在同目录 `verification.json`，构建日志在 `logs/local-candidate/build.log`。复用 `.build/mac-release`、`.build/swiftpm-cache` 和工作区内模块缓存；只保留一份当前候选包，替换前核对旧包的完整文件清单，并拒绝替换正在运行的候选程序。源码哈希、Git 提交、未提交改动、构建配置、架构、签名、离线资源和耗时均写入记录，不能把打包成功当成测试通过。

本地候选版与 GitHub 正式版可以暂时不同。小迭代不必反复提升正式版本号；用提交和文件哈希区分实际源码。每批向用户说明实际代码改动、验证范围、候选版安装状态、正式版发布状态和下一步；只有重新运行过的检查才称为本批通过。

### 阶段发布

完整 macOS 构建使用 GitHub Actions 的 **Build macOS App** 工作流：在 macos-26 / Xcode 26.6 上运行 Core、原生界面与 WebKit 检查，再合并 arm64 和 x86_64 为 Universal App。发布包附版本、源码提交与 SHA-256。验证与交付明细按批次保存在 `Design/`，版本历史见 [CHANGELOG](CHANGELOG.md)。已完成的同源验证结果应复用，不因补写交付文档重新触发构建。

本机完整测试需要完整 Xcode；只有 Command Line Tools 时不应声称 `swift test` 已运行成功。本机独立 Core 检查和原生探针可服务快速迭代，但不等同于完整 XCTest；阶段发布仍要完成完整回归。

```bash
swift test --scratch-path .build/tests --cache-path .build/swiftpm-cache
bash scripts/build-macos.sh
```

阅读器使用系统 PDFKit；Markdown 渲染资源随应用打包，不依赖在线 CDN。资源许可及校验值见 [第三方说明](Sources/ReadingBook/Resources/Markdown/THIRD_PARTY.md)，排版样例见 [Examples](Examples/)。原始 HTML 不执行，远程图片不自动加载。

每轮先保护已有改动和书库，使用隔离副本验证，安装前正常退出并重新保存最新回滚资料。不能用开工快照覆盖用户后来产生的数据。局部对照收益应写清测试范围，不能外推为整个应用或模型网络速度。

源码、构建、缓存、日志和保护文件放在项目工作目录。原生探针共用 `.build/shared-module-cache/`，不为每个实验复制系统模块缓存。每轮结束清理可再生成的过期程序、旧编译中间产物和重复载荷，保留源码、原书、笔记、分析、关键证据和必要回滚。

运行 `python3 scripts/clean-workspace.py` 先预览，明确执行 `--apply` 才清理。进程保护、允许范围和报告见 [工作区清理说明](scripts/WORKSPACE_CLEANUP.md)。清理前后磁盘占用与整批净变化分别记录；不要直接删除可能含唯一证据的实验目录。
