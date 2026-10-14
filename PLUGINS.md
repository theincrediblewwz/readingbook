# 插件与 AI 工具

内置功能通过 `PluginEngine` 注册为模型可调用的工具；声明包为这些能力提供新的类型、读书法和视图组合。新建卡片类型不需要编译新版 App。

## 声明包

在 App 的插件面板选择一个 JSON 文件安装到当前书。完整示例见 `Examples/math-plugin.json`。

```json
{
  "id": "my-plugin",
  "name": "我的领域",
  "version": 1,
  "description": "这个插件适用于哪些内容",
  "types": [{"id":"my-concept","name":"概念","icon":"lightbulb","fields":[{"key":"definition","label":"定义","required":true}]}],
  "methods": [{"id":"my-reading","name":"概念精读","goal":"保留定义与依赖","steps":["找出定义","检查条件","追踪依赖并引用原文"]}],
  "views": [{"id":"my-cards","title":"概念卡","kind":"cards","typeIDs":["my-concept"]}]
}
```

ID 为 1–128 位 ASCII 字母、数字、点、下划线、短横线。禁止远程引用、脚本、Shell 和任意文件路径。字段值目前为字符串；经纬度、事件时间和对象关联使用宿主的结构字段。

视图 `kind` 支持 `cards / timeline / map / mindmap / relations / knowledge / editor / query / workflow`。组件读取同一个书项目中的稳定对象。地图和时间轴围绕事件与地点关联；文档节点引用 Markdown 文档 ID，不复制正文。

停用声明包保留历史知识和类型定义，阻止后续新选用包内读书法、视图和新类型对象。已有对象仍可追溯；重新启用后声明恢复可用。使用已停用读书法的旧计划需要重新预读。

## AI 执行

| 工具 | 作用 |
| --- | --- |
| `knowledge_search` | 只读查找已保存要素，复用索引样本之外的对象 |
| `types_define` | 新增字段化内容类型 |
| `cards_upsert` | 有证据的实体创建与补充 |
| `events_upsert` | 时间、地点、参与者和事件 |
| `relations_link` | 创建有原文依据的关系 |
| `views_configure` | 按书激活组件和字段类型筛选 |
| `methods_define` | 自定义阅读步骤 |
| `reading_plan` | 保存读书法、理由与关注点 |
| `map_attach` / `timeline_attach` | 将同一个事件关联到时空视图 |
| `reading_finish` | 校验当前全部获准单元并保存分析 |

预读只开放配置工具；精读每次提供一个有序源单元、上一单元衔接、已选方法和对象索引。模型多轮调用工具并收到实际结果；`reading_plan` / `reading_finish` 是相应阶段的完成边界，包含它的整个工具批次校验通过且无未修复错误时，步骤才交给仓库保存。截断或异常响应不提交；不会为确认工具成功再额外花一次请求。

新知识必须带 `evidence: [{"unitID":"unit-000001","quote":"原文精确连续片段"}]`。越界引用、未知对象、错误字段或不完整覆盖会失败。AI 没有写用户 Markdown、任意 SQL、文件系统或网络检索工具。

`LibraryRepository` 负责落盘；`BookProject` 是共同数据契约；`WorkspaceSelection` 的首版实现位于 AppStore 的选中对象与时间范围。扩展源码渲染器时，在 `ComponentKind`、`WorkspaceView` 和工具 schema 中明确注册；保持证据、范围与对象身份校验。

普通问答为只读。保存为 Markdown 是用户主动执行的应用操作，与 AI 自动创建书本分析要素分开。
