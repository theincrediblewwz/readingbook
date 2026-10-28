# Prototype Instructions

用户于 2026-10-16 选定第 1 版「霜银 · 钴蓝」。此主题覆盖整个软件；沿用顶部独立悬浮组、可收起的图标导航、可拖动/关闭/恢复的玻璃面板。地图只使用一根双端时间轴，导图单击预览、双击文档，节点列表在右侧。当前交付是浏览器交互稿，AI/OCR/插件写入用明确标识的本地模拟，不接真实密钥或生产数据；后续还原 SwiftUI 需另行做 Mac 验收。

用户于 2026-10-24 要求阅读页左上保留相邻两个入口：最左是功能导航，右侧是阅读导航（目录、缩略图、书签、查找等）；底座保持精简。单页与连续使用明确选项，译注方式点击展开，不依赖悬停子菜单。选中底色与按钮轮廓对齐，浮卡有清晰边缘与阴影，AI 服务不重复标题或留无用空白；小窗口展开内容仍可滚动、关闭。

用户于 2026-10-25 批准 0.20 阅读体验方案：浮卡采用单层自然阴影与细高光，导航随实际项目数收缩；伴读按人物、地点等分组，支持字号、放大与收起保草稿。默认老师伴读，另选原文考据；纯阅读和功能协作是独立的上下文开关。标准分析可按页、章或自适应分块，附加步骤可删，基础阅读始终保留；已分析与逐段精读分别记账。句旁译注可移入、固定和关闭，真实关联组件按需展开；请求详情要显示实际操作。原型所有 AI/进度仍是明确本地示例，不冒充原生结果。

Run the local server yourself and open the preview in the browser available to this environment. Do not give the user server-start instructions when you can run it.

Before making substantial visual changes, use the Product Design plugin's `get-context` skill when the visual source is unclear or no longer matches the current goal. When the user gives durable prototype-specific design feedback, preferences, or decisions, record them in `AGENTS.md`.

When implementing from a selected generated mock, treat that image as the source of truth for layout, component anatomy, density, spacing, color, typography, visible content, and hierarchy.

Build app UI in `src/`. Keep `.openai/hosting.json`, `worker/index.js`, `scripts/prepare-sites-build.mjs`, and `tests/sites-worker.test.mjs` intact so the same local prototype can be handed to Sites. Before a Sites handoff, run `npm run build` and `npm run test:sites`; the build must leave `dist/client/index.html`, `dist/server/index.js`, and `dist/.openai/hosting.json`.
