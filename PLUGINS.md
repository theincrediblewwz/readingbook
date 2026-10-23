# 插件与 AI 工具

## 0.13.1：模型配置与导入校验

`views_configure` 的 `rendererID` 必须与 `PluginEngine.modelRendererKinds` 的实际种类一致，包含 `math.verify → knowledge` 和 `book.scheme → workflow`；模型提示与解析器使用同一组有效元数据。未知模型请求仍拒绝；已保存的未知历史配置保留，不能冒充可执行插件。

加载和导入会校验独立数学记录、方案预览、配置历史和模板。数学记录不能只写 `verified`，宿主按原输入重算，并核验原文依据及工作流归属；软删除也不跳过校验。合法但已过期的方案可以保留供查看/放弃，只有采纳或撤销时要求当前状态匹配。

AI 响应在接收头和每个分块时限制为 4 MiB，拒绝重定向与异常 token 计数；预算使用检查式算术。传输取消、错误体与超限用离线 URLProtocol 夹具回归，不需要真实付费模型调用。

## 0.13：方案事务与数学核查

AI 预读只生成 `bookSchemes.pending`。书本方案页通过注册的 `book.scheme` 渲染器提供预览、组件/类型/执行方法选择、采纳、模板 JSON 与最近 20 次配置历史。未处理 pending 时精读被阻止；配置与原文散列均匹配才允许采纳，OCR 改动使旧预览失效。撤销仅回退配置，保留已被知识和流程引用的定义及用户内容；后续配置冲突直接停止。

同 ID 声明包只能以更高整数版本进入升级预览。发生改变的类型/方法使用版本化 ID，旧对象与回执继续引用旧定义。模板仅含类型、方法、视图、计划和声明包启停配置，不携带原书/笔记；不支持任意代码执行。浏览器原型数据不写入真实书库。

`builtin.math-verification` 通过同一 `PluginToolRegistry` 注册 `math_verify`；`math.verify` 是实际工作流动作与原生结果渲染器，默认方法 `math-verification-v1` 可以被 AI 或方案选择。参数为明确的数字矩阵及 swap/scale/add 步骤，行号从 1 开始。宿主以检查溢出的 Int64 有理数计算 RREF、唯一/无穷/无解与精确回代；最多 8 行 9 列、128 步、每书 256 条记录，越界、未知符号、零分母或溢出拒绝计算。未嵌入通用 CAS 或执行外部脚本。

AI 调用必须先通过当前原文回执门禁，`input` 保留证据原文，结构化 matrix 明确标为 AI 转录；只能追加核查历史。真实产物绑定本步骤及本次尝试 ID，宿主重新计算核对后才允许流程完成。计算发现不一致必须保留 issues；无适用数字时需要具体 `noChangesReason`。用户可以手动核查、将结果转 Markdown 草稿、软删除和恢复，已保存文档保持独立。

算法接口参考 [SymPy 官方矩阵文档](https://docs.sympy.org/latest/modules/matrices/matrices.html) 的初等行变换和 Gauss–Jordan 约定；运行时使用本项目原生有理数实现，开发时不调用真实付费模型。数值核查不等于证明 AI 转录、OCR 或原书论证正确。

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
| `read_receipt` | 仅提交宿主当前批次逐段清单的简短复述及精确首尾锚点；缺段、重复或哈希/范围不符均拒绝 |
| `map_attach` / `timeline_attach` | 将同一个事件关联到时空视图 |
| `reading_finish` | 全部回执通过后，校验当前全部获准单元、每个读书法步骤结果，再保存分析 |

预读只开放配置工具；精读每次提供一个有序源单元、上一单元衔接、已选方法和对象索引。模型多轮调用工具并收到实际结果；`reading_plan` / `reading_finish` 是相应阶段的完成边界，包含它的整个工具批次校验通过且无未修复错误时，步骤才交给仓库保存。截断或异常响应不提交；不会为确认工具成功再额外花一次请求。

0.3 在知识提取前先运行单独的回执阶段，只开放 `read_receipt`。清单由宿主生成，记录源文本哈希、UTF-8 半开范围和源行；批次由输出预算决定，不固定十页。每批成功先保存检查点，下一批只发送缺失项。全单元回执齐后才发送完整原文、已收回执与选定方法，开放事实工具。`reading_finish.stepResults` 必须覆盖宿主给出的全部步骤 ID，结果引用该单元已通过的片段；不适用也须说明理由。

`paragraphReceipts` / `readingStepResults` 是新增可选持久化字段；旧项目无此字段时保留历史笔记，不伪造回执。AI 不能用自定义读书法跳过宿主的清单和证据门禁。清单覆盖的是导入文本，不能替代 OCR 与原页完整性的核对。

新知识必须带 `evidence: [{"unitID":"unit-000001","quote":"原文精确连续片段"}]`。越界引用、未知对象、错误字段或不完整覆盖会失败。AI 没有写用户 Markdown、任意 SQL、文件系统或网络检索工具。

`LibraryRepository` 负责落盘；`BookProject` 是共同数据契约；`WorkspaceSelection` 的首版实现位于 AppStore 的选中对象与时间范围。扩展源码渲染器时，在 `WorkspaceComponentRegistry` 注册原生工厂，在 `PluginEngine.modelRendererKinds` 与工具 schema 声明模型可选的 renderer/kind；新增种类时同步更新 `ComponentKind`。执行工具通过 `PluginToolRegistry` 注册；保持证据、范围与对象身份校验。

普通问答为只读。保存为 Markdown 是用户主动执行的应用操作，与 AI 自动创建书本分析要素分开。
