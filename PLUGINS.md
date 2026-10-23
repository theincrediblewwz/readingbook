# 插件与 AI 工具

## 0.16：智能阅读与可组合页面

导入不发起模型调用。`SmartReadingSelection` 冻结为 `SmartReadingSession`，选择页、章、全书或页码范围；空方法偏好表示AI自己决定。推荐方法改为历史、战争、小说、论述、教材，未退役的旧定义/哈希仍可执行但不再推荐；含已退役动作的旧方案须重新预读。预读只保存待确认方案，用户确认后逐段回执→实际动作→引用核验→所选范围综合；预算结束等待主动继续。范围、确认与任务状态由宿主维护，插件不能改写。

后台`reading_graph`经同一注册接口开放给reading/workflow阶段，要求当前段落回执齐全。`targetIDs`选择当前真实证据支持的既有实体/事件，创建或复用持久导图节点；`relationIDs`只沿现存同端点、同标签且有本段依据的关系连线，不能凭身份候选、参与关系或任意坐标造事实。稳定ID与原子提交保证重试不重复，旧节点标题、坐标、文档挂载及真实Markdown不改；回复提供节点/边ID映射，过大批次原子拒绝。普通问答仍须本次显式授权走受控提案，不能借后台工具写入。

`views_configure` 和现有受控书本方案可声明 `rendererID: reading.composition`、`kind: knowledge`、`composition`。同一渲染器下各页面按viewID独立导航/移除。布局只支持row/column/tabs/overlay/part，使用有限节点ID引用；宿主拒绝环、多父、未使用或不可达节点。元件为object.list、object.detail、source.excerpt、document.markdown、time.axis、geo.map、relation.graph、document.graph。

数据源指定objects/events/relations/documents/evidence、current/book范围、已声明类型和字段、有限筛选、顺序及limit；选择组与时间组共享真实对象和时点。book仍服从宿主剧透边界，current服从实际选段/页，不能用伪选择扩大范围。人物时点行动、地点与参与分别查询，不把参加战役推为人物位置；文档图的物理画布连线标明是布局关联。Markdown正文由原生元件按需读取获准真实文件，配置中不携带正文。

初版最多12数据源、24元件、48布局节点、6层、64KB；每数据源最多200项，地图点/图边另有诚实截断提示。配置不能携带脚本、任意表达式、外部请求或自动模型调用。点击选择、切时间、原文跳转不会申请新增写权限；修改知识/笔记继续走原工具的范围、证据、差异和回执。协议结构见 `CompositionModels/CompositionSchema`，可导入示例见 [history-workbench.plugin.json](Examples/history-workbench.plugin.json)。

分析阶段的已有知识索引、阅读层与knowledge_search均使用宿主获准原文；范围外仅允许当前原文确实出现的身份候选ID用于去重，不提供后文摘要、属性、其他称谓或未附加笔记。前序派生分析要求全部来源处于所选已到达范围，仍不充当原书证据；原始聊天和真实Markdown继续独立保存。

## 0.15：公共模型目录、有界上下文与本次授权

模型目录新增 OpenCode Go、OpenCode Console、OpenRouter 和 MiMo 的 Chat 协议预设；不同网关分别核对型号与限额，未确认的上限保持空缺。运行期目录由内置基线与独立覆盖文件合成，供服务选择和 Max 推荐读取。用户主动点击“AI 检查官网”后，独立助手使用当前模型的请求额度，只获得公共目录、更新要求和本次实际读取的资料；没有读取连接配置、Key、原书、笔记或聊天的工具，也没有保存权限。仅开放 `catalog_read`、`catalog_public_feed`；额外官网链接由用户明确添加，AI 不能修改允许读取的地址范围。

目录提案按精确型号、服务商、字段和实读引文核验，新增或改变的端点也须有官网依据。用户审阅逐项差异后才能应用；保存使用版本冲突检查与原子写入，支持回退上次目录，遗漏项不会被删除。目录更新只改变公共推荐值：已保存服务的地址、选中型号、参数和钥匙串不被自动改写，切换或保存连接仍由用户操作。

问答按本次范围冻结原文与笔记权限；附加笔记和画布节点分别显式选择，选中节点不等于共享其挂载正文。正文按需分段读取，较早问答使用有来源的派生记忆与近期消息，原始记录保留并可重读；记忆失效时回退原记录。问答与目录助手都为最终回答或提案预留预算，必要时以有界实读片段重建请求；预算不足停止继续读取，不把目录、摘要或操作回执冒充原书依据。

普通问答仍默认只读。仅本次显式授权才开放对应整理提案；已有内容修改先审阅差异，新内容以宿主实际提交回执为准。本次已成功创建的对象可继续引用，不能借此读取其他笔记或扩大节点权限。记忆、书中内容和旧操作状态均不能签发新授权；下方 0.14 的受控写入、证据校验与撤销边界继续适用。

## 0.14：已接入的范围工具与受控整理

用户已批准 [28 个接口方案](Design/2026-10-reader-redesign/PROPOSAL.md)。本版在 `ReadingQueryToolCatalog` 注册 18 个读取、6 个宿主界面动作、4 个受控提案；只按本次冻结范围与宿主授予的能力加载，不把全部 schema 无条件交给普通问答。

| 能力组 | 实际工具 |
| --- | --- |
| 原文与覆盖 | `source_outline`、`source_search`、`source_read`、`reading_coverage_get` |
| 对象与时空 | `objects_search`、`object_get`、`relations_list`、`events_query`、`entity_history_get` |
| 笔记与会话 | `documents_list`、`documents_search`、`document_read`、`conversation_search`、`conversation_read` |
| 能力与界面观察 | `capabilities_list`、`book_schema_get`、`workspace_context_get`、`visible_objects_list` |
| 界面动作 | `view_select`、`view_focus`、`view_set_time_window`、`map_fit_objects`、`graph_focus`、`panel_present` |
| 受控整理 | `knowledge_changes_propose`、`graph_changes_propose`、`document_changes_propose`、`book_scheme_propose` |

笔记正文懒加载，引用只接受实际返回的范围片段；工具读取不会增加精读覆盖。界面动作等待真实渲染器回执；当前可见对象只接入图画布，其他渲染器返回 `unsupported`。界面聚焦、相机和时间查询不改节点保存坐标，也不会在用户拖动时抢占。

问答默认没有写提案工具。读者明确允许本次整理后，宿主签发范围授权；符合任务的新内容可原子创建，修改已有笔记、节点、知识或方案先展示完整差异。AI 无权签发授权、批准提案、选择文件路径或永久删除。正文使用原始字节哈希校验，备份为真实 Markdown，事务回执可防重试重复写入，撤销只处理本批对象并保护后续编辑。待审提案不跨进程保留；已提交回执和备份持久化。预览保留量超过上限直接拒绝，不截掉正文让读者盲目批准。

后台精读通过同一 `PluginToolRegistry` 注册的 `builtin.temporal-knowledge` / `knowledge_temporal` 写入时态实体；它受当前逐段回执、获准单元和精确引文门禁，不能修改用户 Markdown 或读者偏好。此工具属于精读/工作流，和上方 28 个问答工具分开。新时态数据为可选附加记录，旧实体/事件/文档 ID 保持稳定，不做破坏迁移；不声称与 Lumen 存储格式兼容。

下方 0.13.x 章节为历史协议和退役说明，以本节与当前注册源码为准。

## 0.13.2：退役能力与下一版接口提案

数学核查 `math.verify` / `math_verify`、原文索引 `reading.mentions` 和思考卡 `reading.decisions` 不再对新任务开放。旧 Codable、验证器与历史记录保留兼容，不删除笔记；旧计划使用数学核查或明确生成思考卡的 `layered-reading-v1` 时需重新预读。新伴读方法 `layered-reading-v2` 只生成适用释义、译文、对象提及和资料对齐，`reading_enrich` 拒绝新的 decisions 字段。

下方旧版本章节仅说明历史协议，不代表退役工具仍可调用。新一轮拟公开的原文/文档/会话读取、节点/文档挂载、实体时空与视图接口共 28 个，详见 [下一版方案](Design/2026-10-reader-redesign/PROPOSAL.md)；尚未写入可调用 schema，待用户评审。

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
