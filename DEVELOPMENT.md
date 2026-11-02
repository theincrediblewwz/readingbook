# 开发与验证

完整 macOS 构建使用 GitHub Actions 的 **Build macOS App** 工作流：在 macos-26 / Xcode 26.6 上运行 Core、原生界面与 WebKit 检查，再合并 arm64 和 x86_64 为 Universal App。发布包附版本、源码提交与 SHA-256。验证与交付明细按批次保存在 `Design/`，版本历史见 [CHANGELOG](CHANGELOG.md)。

本机完整测试需要完整 Xcode；只有 Command Line Tools 时不应声称 `swift test` 已运行成功。可先做本机 Release 编译与独立原生探针，完整 XCTest 仍须通过远端工作流。

```bash
swift test --scratch-path .build/tests
bash scripts/build-macos.sh
```

阅读器使用系统 PDFKit；Markdown 渲染资源随应用打包，不依赖在线 CDN。资源许可及校验值见 [第三方说明](Sources/ReadingBook/Resources/Markdown/THIRD_PARTY.md)，排版样例见 [Examples](Examples/)。原始 HTML 不执行，远程图片不自动加载。

每轮先保护已有改动和书库，使用隔离副本验证，安装前正常退出并重新保存最新回滚资料。不能用开工快照覆盖用户后来产生的数据。局部对照收益应写清测试范围，不能外推为整个应用或模型网络速度。

源码、构建、缓存、日志和保护文件放在项目工作目录。原生探针共用 `.build/shared-module-cache/`，不为每个实验复制系统模块缓存。每轮结束清理可再生成的过期程序、旧编译中间产物和重复载荷，保留源码、原书、笔记、分析、关键证据和必要回滚。

运行 `python3 scripts/clean-workspace.py` 先预览，明确执行 `--apply` 才清理。进程保护、允许范围和报告见 [工作区清理说明](scripts/WORKSPACE_CLEANUP.md)。清理前后磁盘占用与整批净变化分别记录；不要直接删除可能含唯一证据的实验目录。
