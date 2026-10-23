const sourceMath = {page:1,paragraph:2,text:'行变换不改变方程组的解集。先消去第一列，再寻找主元。'};
const sourceHistory = {page:1,paragraph:2,chapter:'第四十九回',text:'孔明曰：万事俱备，只欠东风。'};
export const books = [
  {id:'math',title:'线性代数 · 习题解析',author:'自编阅读样本',kind:'pdf',pages:3,description:'公式、证明与逐段精读',color:'blue'},
  {id:'history',title:'三国演义',author:'历史阅读示例',kind:'text',pages:3,description:'时间、地点与人物的关联阅读',color:'silver'},
];
const doc = (id,bookId,title,markdown,source) => ({id,bookId,title,markdown,source,deleted:false,updatedAt:'2026-10-16'});
export const documents = [
  doc('math-note','math','为什么行变换不改变解集',[
    '# 为什么行变换不改变解集','','消元的每一步，都应该能够逆转。','','例如，将第二行替换为','','$$R_2 \\leftarrow R_2 - 2R_1$$','',
    '这是用第一行的 2 倍去减第二行。这一步不会改变方程组的解集，因为它只是用方程的线性组合替换原来的方程。','','## 三种基本行变换','',
    '1. 交换两行：$R_i \\leftrightarrow R_j$','2. 将某一行乘以非零常数：$R_i \\leftarrow kR_i,\\quad k\\ne0$','3. 用某一行的倍数加到另一行：$R_i \\leftarrow R_i+kR_j$','',
    '这三种变换都是可逆的，因此解集保持不变。','','> 原文 · 第 1 页','> 行变换不改变方程组的解集。先消去第一列，再寻找主元。'
  ].join('\n'),sourceMath),
  doc('m-pivot','math','主元与自由变量','# 主元与自由变量\n\n主元列决定基本变量，非主元列对应自由变量。\n\n$$x_3=t,\\quad t\\in\\mathbb R$$\n\n判断自由变量之前，要先观察系数矩阵的秩。',sourceMath),
  doc('m-matrix','math','从消元到矩阵','# 从消元到矩阵\n\n把系数与常数项排列在一起，就得到增广矩阵。\n\n$$[A\\mid b]$$\n\n每一行都对应一条方程。',sourceMath),
  doc('m-question','math','我的疑问','# 我的疑问\n\n如果有一行化为 $0=1$，方程组为什么无解？\n\n- 回到原式检查约束\n- 尝试一个最简单的例子',sourceMath),
  doc('h-main','history','赤壁之战','# 赤壁之战\n\n以少胜多，三国鼎立的转折点。\n\n## 阅读线索\n\n孙刘联盟、连船、风向与选择时机，形成相互依赖的条件。',sourceHistory),
  doc('h-alliance','history','孙刘联盟','# 孙刘联盟\n\n孙权与刘备结盟，共御曹操。\n\n联盟既是战略选择，也受各方立场影响。',sourceHistory),
  doc('h-fire','history','火攻的条件','# 风向、连船与时机\n\n东南风为火攻创造了有利的自然条件。曹军连船使火势迅速蔓延，而战机的把握则决定了火攻的成功。\n\n## 仍需核对\n\n小说叙述与史实记载要分别标注。',sourceHistory),
  doc('h-people','history','人物与立场','# 人物与立场\n\n曹操、孙权、刘备及其谋士，拥有不同的目标与约束。\n\n从行动回看人物动机，而非只记人名。',sourceHistory),
  doc('h-question','history','我的疑问','# 我的疑问\n\n火攻为何能成功？\n\n- 必要条件是什么？\n- 哪些是小说中的叙事安排？',sourceHistory),
  doc('h-understanding','history','从原文到理解','# 从原文到理解\n\n关键情节与历史启示。\n\n把原文证据、AI分析与我的判断分别记录。',sourceHistory),
];
const graphPositions = [[480,440],[160,220],[800,220],[120,590],[850,590],[520,760]];
export const graphNodes = documents.map((d,i)=>{const p=d.bookId==='history'?graphPositions[i-4]:[[330,330],[720,200],[740,540],[180,610]][i];return {id:'n-'+d.id,bookId:d.bookId,docId:d.id,x:p[0],y:p[1]};});
export const graphEdges = [
  ...['h-alliance','h-fire','h-people','h-question','h-understanding'].map((id,i)=>({id:'he'+i,bookId:'history',from:'n-h-main',to:'n-'+id,label:i===1?'条件':''})),
  ...['m-pivot','m-matrix','m-question'].map((id,i)=>({id:'me'+i,bookId:'math',from:'n-math-note',to:'n-'+id,label:''})),
];
export const initialState = {
  route:'reader',currentBookId:'math',page:1,source:null,selectedDocId:'math-note',
  documents,graphNodes,graphEdges,readingScope:'book',timeRange:[208,209],
  profiles:[
    {id:'deepseek',name:'DeepSeek',provider:'deepseek',baseURL:'https://api.deepseek.com',modelId:'deepseek-chat',maxTokens:32768,maxOutputTokens:32768,vision:false,status:'saved',example:true},
    {id:'qwen',name:'通义千问',provider:'qwen',baseURL:'https://dashscope.aliyuncs.com/compatible-mode/v1',modelId:'qwen-demo',maxTokens:8192,maxOutputTokens:32768,vision:true,status:'saved',example:true},
    {id:'openai',name:'OpenAI',provider:'openai',baseURL:'https://api.openai.com/v1',modelId:'example-model',maxTokens:8192,maxOutputTokens:32768,vision:true,status:'saved',example:true},
    {id:'claude',name:'Claude',provider:'anthropic',baseURL:'https://api.anthropic.com/v1',modelId:'example-model',maxTokens:8192,maxOutputTokens:32768,vision:true,status:'saved',example:true},
  ],activeProfileId:'deepseek',
  enabledPlugins:['reader','spatial','mindmap','knowledge','workflow'],
  addedComponents:['spatial','mindmap','knowledge','cards','relations'],
  typeDefinitions:[
    {id:'theorem',bookId:'math',name:'定理',fields:['条件','结论','证明','原文出处'],origin:'AI 建议'},
    {id:'concept',bookId:'math',name:'概念',fields:['定义','例子','原文出处'],origin:'默认类型'},
    {id:'person',bookId:'history',name:'人物',fields:['立场','经历','原文出处'],origin:'默认类型'},
    {id:'event',bookId:'history',name:'事件',fields:['时间','地点','参与者','原文出处'],origin:'AI 建议'},
    {id:'place',bookId:'history',name:'地点',fields:['名称','关联事件','原文出处'],origin:'默认类型'},
  ],
  readingMethods:[
    {id:'genre.history',name:'历史阅读',description:'按原书证据连接人物、事件、时间与地点。',steps:['逐段复述与核对','保存实体、事件与时态','建立原文解释','回顾变化与疑点']},
    {id:'genre.war',name:'战争阅读',description:'联系战役阶段、决策、地理与结果。',steps:['辨明战争背景','保存战役、参与与地点','核对出处和时态','比较条件与结果']},
    {id:'genre.fiction',name:'小说阅读',description:'关注作品内人物、叙事与主题。',steps:['跟随叙事视角','复用人物及关系','解释称谓和词句','回顾动机与主题']},
    {id:'genre.argument',name:'论述阅读',description:'厘清问题、主张、证据与推理。',steps:['辨明核心问题','保存概念和论证','解释术语与条件','回查边界和反例']},
    {id:'genre.textbook',name:'教材阅读',description:'联系定义、条件、证明与先修依赖。',steps:['核对公式和条件','保存概念与依赖','解释推导线索','回顾易混概念']},
  ],
  workflow:{status:'idle',receipts:[],pluginLog:[],methodId:'close',cursor:0},
  messages:[{id:'a1',bookId:'math',role:'assistant',text:'行变换不改变方程组的解集，是因为每一步都有逆操作。\n\n例如 $R_2\\leftarrow R_2-2R_1$，可通过 $R_2\\leftarrow R_2+2R_1$ 恢复。'},{id:'a2',bookId:'math',role:'assistant',text:'可以把每一步消元写成一个小清单：操作是什么、能否逆转、改变了哪些系数。\n\n普通回答不会自动成为笔记；你可以选段或合并保存。'}],
  annotations:[],searchOpen:false,
};
