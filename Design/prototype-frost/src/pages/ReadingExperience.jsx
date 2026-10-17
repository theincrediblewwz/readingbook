import React,{useState} from 'react';
import {useApp,Button,Icon,Markdown,Modal} from '../shared.jsx';
import './experience.css';

const samples={
  math:[
    {id:'row',page:1,lines:'12–21',title:'行变换的可逆性',quote:'行变换不改变方程组的解集。先消去第一列，再寻找主元。',kind:'explanation',name:'为什么每一步都必须可逆',markdown:'初等行变换有三种基本操作：交换两行、将一行乘以非零数，以及将一行的倍数加到另一行。它们都可以逆转，因此不会改变解集。\n\n例如，把第二行替换为\n\n$$R_2\\leftarrow R_2-2R_1.$$\n\n逆操作是 $R_2\\leftarrow R_2+2R_1$。这只是方程的线性组合，没有增加新的约束。'},
    {id:'pivot',page:2,lines:'8–16',title:'主元与自由变量',quote:'主元列决定基本变量，非主元列对应自由变量。',kind:'commentary',name:'先看约束，再引入参数',markdown:'自由变量的存在，与未知数和独立约束的数量有关。\n\n$$x_3=t,\\quad t\\in\\mathbb R.$$\n\n选一个参数值代回原式，是核对推导的直接方法。'},
    {id:'rank',page:3,lines:'30–39',title:'增广矩阵与解集',quote:'如果消元后出现 0=1，方程组没有解。',kind:'explanation',name:'矛盾行表达了什么',markdown:'这一行表达了一个不可能成立的等式。它不是“一个新的变量”，而是全部约束无法同时成立的证据。'},
  ],
  history:[
    {id:'wind',page:1,lines:'12–21',title:'风向与时机',quote:'时东南风急，黄盖将中军船帆扯足，望曹操水寨，乘风而去。',kind:'explanation',name:'叙事中的火攻条件',markdown:'风向、连船和行动时机是这里的三条线索。\n\n小说描写与历史事实要分别核对，不能只因文字具体就视为史实。'},
    {id:'alliance',page:2,lines:'8–16',title:'联盟与立场',quote:'刘备与孙权联合迎战曹操。',kind:'translation',name:'用自己的话复述',markdown:'两个目标不同的阵营，为了应对共同威胁暂时合作。具体约定需要回到原书核对。'},
    {id:'place',page:3,lines:'30–39',title:'战后的空间线索',quote:'操引众将奔华容道而去。',kind:'commentary',name:'地名也是线索',markdown:'地名连接起事件的行动顺序。地图标记只是阅读辅助，不替代历史地理考证。'},
  ]
};
const kindNames={all:'全部',explanation:'释义',translation:'译文',commentary:'评注',reference:'资料对读'};

export function LayersPage(){
  const {book,navigate,notify}=useApp(),rows=samples[book.id]||samples.math;
  const [selected,setSelected]=useState(rows[0].id),[kind,setKind]=useState('all'),[scope,setScope]=useState('book'),[query,setQuery]=useState(''),[directory,setDirectory]=useState(window.innerWidth>=1000),[removed,setRemoved]=useState([]),[confirm,setConfirm]=useState(null),[run,setRun]=useState(false);
  const row=rows.find(r=>r.id===selected)||rows[0],available=rows.filter(r=>(scope==='book'||r.page===row.page)&&(!query||`${r.title} ${r.quote}`.includes(query)));
  const present=!removed.includes(row.id)&&(kind==='all'||kind===row.kind);
  function source(){navigate('reader',{page:row.page,source:{page:row.page,paragraph:2,text:row.quote}});}
  function draft(){navigate('notes',{noteDraftRequest:{title:row.name,markdown:'# '+row.name+'\n\n'+row.markdown+'\n\n> '+row.quote,source:{page:row.page,text:row.quote}}});}
  return <section className={'rx-page '+(directory?'has-directory':'')} data-testid="layers-page">
    {directory&&<aside className="rx-directory glass"><header><h2>原文片段</h2><Button icon="sidebar" aria-label="收起原文片段" variant="quiet" onClick={()=>setDirectory(false)}/></header><label className="rx-search"><Icon name="search"/><input aria-label="查找段落" placeholder="查找段落或章节" value={query} onChange={e=>setQuery(e.target.value)}/></label><div className="segmented">{[['book','全书'],['page','当前页']].map(([id,title])=><button key={id} aria-pressed={scope===id} onClick={()=>setScope(id)}>{title}</button>)}</div><div className="rx-source-list">{available.map((r,i)=><button className={'rx-source-row '+(row.id===r.id?'selected':'')} key={r.id} onClick={()=>{setSelected(r.id);if(innerWidth<1000)setDirectory(false);}}><b>{i+1}</b><span><small>第 {r.page} 页 · 行 {r.lines}</small><p>{r.quote}</p></span><Icon name="chevronRight" size={16}/></button>)}{!available.length&&<p className="muted">没有匹配的原文片段。</p>}</div></aside>}
    <article className="rx-reading-paper"><header className="rx-paper-heading"><h1>多层伴读</h1><small>第 {row.page} 页 · 行 {row.lines}</small><span className="spacer"/>{!directory&&<Button icon="sidebar" onClick={()=>setDirectory(true)}>原文片段</Button>}<details className="rx-recovery"><summary title="伴读恢复"><Icon name="undo"/></summary><div className="glass">{removed.length?removed.map(id=><Button key={id} icon="undo" onClick={()=>setRemoved(v=>v.filter(x=>x!==id))}>恢复 {rows.find(r=>r.id===id)?.name}</Button>):<p>暂无已移除的伴读</p>}</div></details></header>
      <div className="rx-reading-scroll"><blockquote className="rx-current-quote">{row.quote}</blockquote><div className="rx-kind-tabs">{Object.entries(kindNames).map(([id,title])=><Button key={id} variant="quiet" aria-pressed={kind===id} onClick={()=>setKind(id)}>{title}</Button>)}</div>
        {present?<><section className="rx-layer-card"><div className="rx-layer-meta"><span><Icon name="sparkle" size={16}/>{kindNames[row.kind]} · AI 示例 · 待核对</span><Button icon="trash" aria-label="移除当前伴读" variant="quiet" onClick={()=>setConfirm(row.id)}/></div><h2>{row.name}</h2><Markdown text={row.markdown}/></section><section className="rx-source-evidence"><header><b><Icon name="book"/>原文依据</b><span className="spacer"/><small>第 {row.page} 页 · 行 {row.lines}</small><Button icon="return" variant="quiet" onClick={source}>回到原句</Button></header><p>“{row.quote}”</p></section></>:<div className="rx-empty"><Icon name="file" size={30}/><h2>这一范围还没有{kindNames[kind]||'伴读内容'}</h2><p>可以切换内容类型或原文片段。移除的条目可在右上角恢复。</p></div>}
        <p className="rx-attribution"><Icon name="info" size={16}/>AI 示例与原书分开标注，请结合原文核对。</p></div>
      <footer className="rx-action-footer"><Button icon="chat" variant="primary" onClick={()=>navigate('chat',{source:{page:row.page,text:row.quote}})}>问这一片段</Button><Button icon="notes" onClick={draft} disabled={!present}>整理为笔记</Button><Button icon="sparkle" disabled={run} onClick={()=>{setRun(true);setTimeout(()=>{setRun(false);notify('增强流程演示结束，没有调用真实模型。');},650);}}>{run?'正在处理…':'增强当前片段 · 演示'}</Button></footer></article>
    {confirm&&<Modal title="移除这条伴读？" onClose={()=>setConfirm(null)} footer={<><Button onClick={()=>setConfirm(null)}>取消</Button><Button variant="primary" onClick={()=>{setRemoved(v=>[...v,confirm]);setConfirm(null);}}>移入伴读回收站</Button></>}><p>原书和笔记保留。可从本页右上角恢复。</p></Modal>}
  </section>;
}

export function SourceIndexPage(){
  const {book,navigate}=useApp(),rows=samples[book.id]||samples.math,[query,setQuery]=useState(''),[scope,setScope]=useState('book'),[type,setType]=useState('all'),[directory,setDirectory]=useState(window.innerWidth>=1000),[active,setActive]=useState('row'),[tab,setTab]=useState('sources'),[coarse,setCoarse]=useState(true);
  const objects=book.id==='math'?[
    {id:'row',name:'初等行变换',type:'概念',aliases:['行变换','初等变换'],summary:'对矩阵（或方程组）的行进行的三种可逆基本变换：交换两行、用非零数乘一行，把一行的倍数加到另一行。初等行变换不改变矩阵的秩，也不改变线性方程组的解集。',occurrences:[{...rows[0]},{...rows[1],quote:'三种基本行变换都是可逆的，因此不会改变方程组的解集。'},{...rows[2],quote:'在判断解集前，先检查所做的行变换是否可逆。'}],evidence:'教材中给出了初等行变换的定义与性质，并说明其可逆性。'},
    {id:'pivot',name:'主元',type:'概念',aliases:['主元位置'],summary:'行阶梯形式中，非零行的首个非零元素提供一个主元位置。',occurrences:[rows[1]]},
    {id:'free',name:'自由变量',type:'概念',aliases:['参数变量'],summary:'没有主元的变量可被选作自由变量，用参数表示解集。',occurrences:[rows[1]]},
    {id:'theorem',name:'齐次方程组',type:'定义',aliases:[],summary:'右端为零的线性方程组。',occurrences:[],evidence:'定义与条件还需要对照原书核查。'},
    {id:'rank',name:'矩阵的秩',type:'概念',aliases:[],summary:'独立约束的数量需要结合具体定义理解。',occurrences:[]},
  ]:[
    {id:'row',name:'赤壁之战',type:'事件',aliases:['赤壁'],summary:'事件连接风向、火攻、联盟与参与者。这里使用小说阅读示例，并不把叙事等同史实。',occurrences:rows,evidence:'历史地理与具体年代需另行核对。'},
    {id:'zhou',name:'周瑜',type:'人物',aliases:['公瑾'],summary:'江东统帅，与联盟和火攻叙事关联。',occurrences:[rows[0]]},
    {id:'place',name:'华容道',type:'地点',aliases:['华容'],summary:'战后撤退叙事中的空间线索。',occurrences:[rows[2]]},
  ];
  const entries=objects.map(o=>({...o,occurrences:o.occurrences.filter(r=>scope==='book'||r.page===1)})).filter(o=>(scope==='book'||o.occurrences.length||o.evidence)&&(type==='all'||o.type===type)&&(!query||`${o.name} ${o.aliases.join(' ')} ${o.occurrences.map(x=>x.quote).join(' ')}`.includes(query))),selected=entries.find(o=>o.id===active)||entries[0],occurrences=selected?.occurrences||[];
  function follow(r){navigate('reader',{page:r.page,source:{page:r.page,text:r.quote}});}
  return <section className="rx-index-page"><header className="rx-index-heading"><h1>原文索引</h1><label className="rx-search glass"><Icon name="search"/><input aria-label="搜索原文索引" placeholder="查对象、别名或原句" value={query} onChange={e=>setQuery(e.target.value)}/><select aria-label="索引范围" value={scope} onChange={e=>setScope(e.target.value)}><option value="book">全书</option><option value="page">当前页</option></select></label>{!directory&&<Button icon="sidebar" onClick={()=>setDirectory(true)}>对象目录</Button>}</header>
    <div className={'rx-index-layout '+(directory?'has-directory':'')}>{directory&&<aside className="rx-directory rx-object-directory glass"><header><h2>对象目录</h2><Button icon="sidebar" aria-label="收起对象目录" variant="quiet" onClick={()=>setDirectory(false)}/></header><div className="rx-type-tabs">{['all',...new Set(objects.map(o=>o.type))].map(id=><Button key={id} variant="quiet" aria-pressed={type===id} onClick={()=>setType(id)}>{id==='all'?'全部':id}</Button>)}</div><div className="rx-object-list">{entries.map(o=><button className={'rx-object-row '+(selected?.id===o.id?'selected':'')} key={o.id} onClick={()=>{setActive(o.id);if(innerWidth<1000)setDirectory(false);}}><Icon name="file" size={25}/><span><b>{o.name}</b><small>{o.type} · {o.occurrences.length?'已定位 '+o.occurrences.length+' 处':o.evidence?'原文依据 1 条':'待定位'}</small></span><Icon name="chevronRight" size={15}/></button>)}</div></aside>}
      <article className="rx-index-detail">{selected?<><header><h2>{selected.name}</h2><span className="badge">{selected.type}</span></header>{selected.aliases.length>0&&<p className="rx-alias"><b>别名</b>{selected.aliases.join('、')}</p>}<p className="rx-object-summary">{selected.summary}</p><div className="rx-detail-tabs">{[['sources','出现位置 '+occurrences.length],['properties','属性与关联']].map(([id,title])=><button key={id} aria-pressed={tab===id} onClick={()=>setTab(id)}>{title}</button>)}</div>
        {tab==='sources'?<><div className="rx-occurrence-title"><h3>原文中的出现位置</h3><small>已定位提及，不代表全文词频。</small></div><ol className="rx-occurrences">{occurrences.map((r,i)=><li key={r.id}><span className="rx-order">{i+1}</span><div><header><b>第 {r.page} 页 · 行 {r.lines}</b><Button icon="return" variant="quiet" onClick={()=>follow(r)}>回到原句</Button></header><p>{r.quote.split(/(行变换|初等变换)/g).map((part,i)=>/^(行变换|初等变换)$/.test(part)?<mark key={i}>{part}</mark>:part)}</p></div></li>)}</ol>{!occurrences.length&&<p className="rx-empty">当前范围没有可精确定位的提及。原文依据与对象资料仍保留。</p>}{selected.evidence&&<section className="rx-coarse"><Button icon="chevronDown" variant="quiet" aria-expanded={coarse} onClick={()=>setCoarse(!coarse)}>原文依据 · 1 条</Button><span className="rx-warning">精确位置待核对</span>{coarse&&<div><p>{selected.evidence}</p><Button icon="book" onClick={()=>follow(rows[0])}>查看所引原文</Button></div>}</section>}</>:<div className="rx-properties"><h3>关联线索</h3><p>来源身份与原文引用保持独立。</p>{objects.filter(o=>o.id!==selected.id).map(o=><Button key={o.id} icon="link" onClick={()=>{setActive(o.id);setTab('sources');}}>{o.name}</Button>)}</div>}
        <footer><Button icon="link" variant="quiet" onClick={()=>setTab('properties')}>查看关联</Button><Button icon="notes" variant="quiet" onClick={()=>navigate('notes',{noteDraftRequest:{title:selected.name,markdown:'# '+selected.name+'\n\n'+selected.summary}})}>写下理解</Button></footer></>:<div className="rx-empty"><h2>没有匹配对象</h2><p>可以清空搜索、切换类型或索引范围。</p></div>}</article>
    </div></section>;
}
