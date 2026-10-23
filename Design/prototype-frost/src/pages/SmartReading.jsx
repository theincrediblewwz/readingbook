import React,{useEffect,useState} from 'react';
import {useApp,Button,Icon} from '../shared.jsx';
import './smart-reading.css';

const genres=[['history','历史','clock'],['warfare','战争','map'],['fiction','小说','book'],['argument','论述','file'],['textbook','教材','knowledge']];
export function SmartReadingPage(){
  const {state,update,book,navigate}=useApp();
  const [automatic,setAutomatic]=useState(true),[selected,setSelected]=useState([]),[scope,setScope]=useState('book'),[from,setFrom]=useState(1),[to,setTo]=useState(3),[preview,setPreview]=useState(false);
  const range=scope==='page'?'当前页':scope==='chapter'?'当前章':scope==='range'?`第 ${from}–${to} 页`:'全书';
  function choose(id){setAutomatic(false);setSelected(old=>old.includes(id)?old.filter(x=>x!==id):[...old,id]);setPreview(false);}
  useEffect(()=>{
    const saved=state.workflow.bookId===book.id?state.workflow.selection:null;
    setAutomatic(saved?.automatic??true);setSelected(saved?.methodIDs||[]);setScope(saved?.scope||'book');setFrom(saved?.from||1);setTo(saved?.to||3);setPreview(false);
  },[book.id]);
  function start(){
    const first=scope==='page'?state.page:scope==='range'?from:1;
    const total=scope==='page'?1:scope==='range'?Math.max(1,to-from+1):3;
    update({workflow:{...state.workflow,status:'running',smart:true,bookId:book.id,selection:{automatic,methodIDs:selected,scope,from,to},scope:scope==='page'?`第 ${first} 页`:range,first,total,cursor:1}});navigate('reader');
  }
  return <section className="smart-page"><div className="smart-content">
    <div className="smart-eyebrow"><Icon name="sparkle" size={18}/>智能阅读</div>
    <h1>安心读，线索会慢慢连起来。</h1>
    <p className="smart-lead">你决定读哪些内容，AI 为这本书选择合适的方法。<br/>分析在后台进行，原书始终在你手里。</p>
    <div className="smart-stages"><span className="active">1 选择方式与范围</span><i/><span className={preview?'active':''}>2 看一眼阅读方案</span><i/><span>3 边读边分析</span></div>
    <div className="smart-grid">
      <article className="smart-card glass"><h2><Icon name="book"/>怎样读这本书</h2>
        <button className={'smart-auto '+(automatic?'selected':'')} aria-pressed={automatic} onClick={()=>{setAutomatic(true);setSelected([]);setPreview(false);}}><Icon name="sparkle" size={28}/><span><b>AI 自己决定</b><small>先看书名、目录和开头，选用或制定专属方法</small></span><Icon name={automatic?'check':'plus'}/></button>
        <div className="smart-genres">{genres.map(([id,label,icon])=><button key={id} className={selected.includes(id)?'selected':''} aria-pressed={selected.includes(id)} onClick={()=>choose(id)}><Icon name={icon}/>{label}{selected.includes(id)&&<Icon name="check" size={17}/>}</button>)}</div>
        <p className="smart-hint">也可以组合书型。历史小说能同时关注人物、时空与叙事。</p>
        <h2 className="smart-range-title"><Icon name="target"/>分析多少</h2>
        <div className="smart-range">{[['page','当前页'],['chapter','当前章'],['book','全书'],['range','指定页码']].map(([id,label])=><button key={id} aria-pressed={scope===id} className={scope===id?'selected':''} onClick={()=>{setScope(id);setPreview(false);}}>{label}</button>)}</div>
        {scope==='range'&&<div className="smart-pages"><label>从第<input type="number" min="1" max="3" value={from} onChange={e=>setFrom(Number(e.target.value))}/></label><label>到第<input type="number" min={from} max="3" value={to} onChange={e=>setTo(Number(e.target.value))}/>页</label></div>}
        <footer><span>{range} · 发送后范围固定</span><Button icon="sparkle" variant="primary" onClick={()=>setPreview(true)} disabled={(!automatic&&!selected.length)||(state.workflow.bookId===book.id&&state.workflow.status==='running')}>预读并制定方案</Button></footer>
      </article>
      <aside className="smart-outline"><small>接下来会发生什么</small><div><span>01</span><section><h3>先了解这本书</h3><p>预读只用于选方法，还没有读完整本书。</p></section></div><div><span>02</span><section><h3>逐段读，再整理</h3><p>每段留下简短复述，再保存有出处的要素和联系。</p></section></div><div><span>03</span><section><h3>在组件里看见结果</h3><p>人物、战役与地点使用同一对象；适用时，地图、时间和关系同步呈现。</p></section></div><Button icon="reader" variant="quiet" onClick={()=>navigate('reader')}>先回原文，稍后再分析</Button></aside>
    </div>
    {preview&&<article className="smart-preview glass"><header><div><small>预读方案 · 交互示例</small><h2>{book.id==='history'?'用人物、时空和因果读这本书':'沿概念、条件与推导读这本书'}</h2></div><Button icon="close" aria-label="收起预读方案" variant="quiet" onClick={()=>setPreview(false)}/></header><p>先逐段核对，再抽取有出处的要素，最后回顾关联和疑问。没有明确位置、时间或人物时，不强行填充。</p><div className="smart-parts">{(book.id==='history'?['要素卡片','时间与地图','关系图谱','本书专属组件']:['概念卡片','思维导图','推导与条件']).map(x=><span key={x}><Icon name="check" size={16}/>{x}</span>)}</div><footer><small>{range} · 可暂停并接着已保存的位置继续</small><Button icon="play" variant="primary" onClick={start}>确认并开始分析</Button></footer></article>}
  </div></section>;
}

export function SmartReadingProgress(){
  const {state,update,navigate}=useApp();const [expanded,setExpanded]=useState(false);
  if(!state.workflow.smart||state.workflow.bookId!==state.currentBookId)return null;
  const running=state.workflow.status==='running';
  return <aside className="smart-progress glass" aria-label="智能阅读进度"><header><button className="smart-progress-summary" aria-expanded={expanded} onClick={()=>setExpanded(!expanded)}><Icon name={running?'sparkle':'pause'}/><span><b>{running?'正在分析':'分析已暂停'}</b><small>{state.workflow.scope} · 第 1 / {state.workflow.total||3} 页</small><i><em/></i></span><Icon name={expanded?'chevronDown':'expand'} size={16}/></button><Button variant="quiet" icon={running?'pause':'play'} aria-label={running?'暂停分析':'继续分析'} onClick={()=>update({workflow:{...state.workflow,status:running?'paused':'running'}})}/></header>{expanded&&<div className="smart-progress-detail"><p><Icon name="check"/>预读并确定阅读方案</p><p><Icon name="check"/>第 {state.workflow.first||1} 页 · 逐段阅读</p><p><Icon name="sparkle"/>正在整理要素与联系</p><small>仅展示实际保存的处理状态；仍可阅读和查看组件。</small><Button icon="workflow" variant="quiet" onClick={()=>navigate('workflow')}>阅读方案与结果</Button></div>}</aside>;
}
