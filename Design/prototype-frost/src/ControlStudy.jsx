import React, { memo, useEffect, useLayoutEffect, useRef, useState } from 'react';
import { Icon, Markdown } from './shared.jsx';
import * as pdfjs from 'pdfjs-dist';
import pdfWorker from 'pdfjs-dist/build/pdf.worker.min.mjs?url';
import './control-study.css';

pdfjs.GlobalWorkerOptions.workerSrc = pdfWorker;
const directions = [
  { id: 'base', name: '阅读底座', short: '工具合为一组，面板向两侧吸附。', detail: '翻页、目录、伴读、提问和批注集中在一条轻薄底座。拖动页码区，整组吸附到下方左、中、右；不再把每个按钮单独散放。' },
  { id: 'edge', name: '边缘工具坞', short: '工具靠右，底部只保留翻页。', detail: '伴读、对话和批注集中在右侧工具坞，面板从同一位置展开。工具坞只沿右侧上下吸附；小窗展开面板时暂收工具坞，收起面板后恢复。' },
  { id: 'focus', name: '沉浸胶囊', short: '默认只留翻页，按需展开工具。', detail: '一枚阅读胶囊承载页码与工具入口。展开后再选择目录、AI 和批注；沉浸时整体退场，按 Esc 或移到窗口下缘唤回。输入、菜单和面板打开时不自动隐藏。' },
];
const sections = ['线性方程组', '行变换与等价方程', '主元、自由变量与解集'];
const initialNotes = String.raw`# 从主元理解解集

主元确定哪些变量被约束；自由变量决定解集如何展开。

$$x_1=2-t,\quad x_2=1+2t,\quad x_3=t$$

> 回到原式检查，比只看化简后的矩阵更可靠。`;
const clamp = (n, a, b) => Math.max(a, Math.min(n, b));
function Control({ icon, children, label, selected, className = '', ...props }) {
  return <button type="button" className={`cs-control ${children ? '' : 'cs-icon'} ${selected ? 'is-selected' : ''} ${className}`} aria-label={label} aria-pressed={selected === undefined ? undefined : selected} title={label} {...props}>{icon && <Icon name={icon} size={19} />}{children}</button>;
}

let samplePDF;
const SamplePage = memo(function SamplePage({ page, zoom }) {
  const canvas = useRef(null);
  const [error, setError] = useState('');
  const [ready, setReady] = useState(false);
  useEffect(() => {
    let active = true, rendering;
    setReady(false); setError('');
    samplePDF ??= pdfjs.getDocument({url:new URL('/assets/math-sample.pdf?revision=2', location.href).href}).promise;
    samplePDF.then(async pdf => {
      const source = await pdf.getPage(page);
      if (!active) return;
      const view = source.getViewport({ scale: 1.7 }), target = canvas.current;
      target.width = view.width; target.height = view.height;
      rendering = source.render({ canvasContext: target.getContext('2d'), viewport: view });
      await rendering.promise;
      if (active) setReady(true);
    }).catch(e => { if (active && e.name !== 'RenderingCancelledException') { console.warn('Control study PDF:', e.message); setError('示例 PDF 暂未载入'); } });
    return () => { active = false; rendering?.cancel(); };
  }, [page]);
  return <div className="cs-pdf-page" style={{ width: zoom === 'fit' ? '100%' : `${Number(zoom)}%` }}>
    {!ready && <p className="cs-pdf-status">{error || '正在载入原 PDF…'}</p>}
    <canvas ref={canvas} aria-label={`原 PDF 第 ${page} 页`} style={{ visibility: ready ? 'visible' : 'hidden' }} />
  </div>;
});

function Popover({ children, className = '', close, style }) {
  const ref = useRef(null);
  useEffect(() => {
    const before = document.activeElement;
    const root = ref.current;
    root?.querySelector('button,input')?.focus();
    const key = e => {
      if (e.key === 'Escape') { e.stopPropagation(); close(); }
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        if (e.target.matches('input,textarea,select,[contenteditable=true]')) return;
        const items = [...root.querySelectorAll('button:not(:disabled),input,select')];
        const index = items.indexOf(document.activeElement);
        if (items.length) { e.preventDefault(); items[(index + (e.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length]?.focus(); }
      }
    };
    root?.addEventListener('keydown', key);
    return () => { root?.removeEventListener('keydown', key); if (before?.isConnected) before.focus?.(); };
  }, []);
  return <><button className="cs-menu-dismiss" aria-label="关闭弹出菜单" onClick={close} tabIndex={-1} /><div ref={ref} className={`cs-popover cs-glass ${className}`} style={style}>{children}</div></>;
}

function ManagementLayer({ children, close }) {
  const ref = useRef(null);
  useEffect(() => {
    const before = document.activeElement, root = ref.current;
    const fallback = root.closest('.cs-frame')?.querySelector('button[aria-label="图书与工作区菜单"]');
    root.querySelector('button')?.focus();
    const key = e => {
      if (e.key !== 'Tab') return;
      const items = [...root.querySelectorAll('button:not(:disabled),input,select,textarea,a[href],summary')].filter(x => x.getClientRects().length);
      if (!items.length) return;
      const first = items[0], last = items.at(-1);
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    };
    root.addEventListener('keydown', key);
    return () => { root.removeEventListener('keydown', key); if (before?.isConnected && before.getClientRects().length) before.focus?.(); else fallback?.focus(); };
  }, []);
  return <div ref={ref} className="cs-management-shade" onPointerDown={e => { if (e.target === e.currentTarget) close(); }}>{children}</div>;
}
function MenuRow({ icon, children, detail, checked, ...props }) {
  return <button className="cs-menu-row" type="button" {...props}><Icon name={icon} size={18} /><span>{children}{detail && <small>{detail}</small>}</span>{checked && <Icon name="check" size={17} />}</button>;
}

function StudyPanel({ open, title, icon, side = 'right', children, close, extra, draggable = false, onDock, frame }) {
  const ref = useRef(null), gesture = useRef(null);
  const [delta, setDelta] = useState(null);
  useEffect(() => { if (!open) { gesture.current = null; setDelta(null); } }, [open]);
  const start = e => {
    if (!draggable || e.button !== 0) return;
    gesture.current = { x: e.clientX, y: e.clientY, left: ref.current.getBoundingClientRect().left };
    e.currentTarget.setPointerCapture(e.pointerId);
  };
  const move = e => {
    const g = gesture.current; if (!g) return;
    if (Math.hypot(e.clientX - g.x, e.clientY - g.y) > 5) setDelta({ x: e.clientX - g.x, y: e.clientY - g.y });
  };
  const finish = e => {
    const g = gesture.current; gesture.current = null; setDelta(null);
    if (g && Math.abs(e.clientX - g.x) > 5) {
      const box = frame.current.getBoundingClientRect();
      onDock?.(e.clientX - box.left < box.width / 2 ? 'left' : 'right');
    }
  };
  return <section ref={ref} hidden={!open} className={`cs-panel cs-glass cs-panel-${side} ${delta ? 'is-dragging' : ''}`} aria-label={title}
    style={delta ? { transform: `translate(${delta.x}px,${delta.y}px)` } : undefined}>
    <header><div className={`cs-panel-title ${draggable ? 'can-drag' : ''}`} onPointerDown={start} onPointerMove={move} onPointerUp={finish} onPointerCancel={() => { gesture.current = null; setDelta(null); }} title={draggable ? '拖动标题，松手吸附到左侧或右侧' : undefined}>
      <Icon name={icon} size={20} /><h2>{title}</h2>
    </div>{extra}<Control icon="minus" label={`收起${title}`} onClick={close} /></header>
    <div className="cs-panel-body">{children}</div>
  </section>;
}

export default function ControlStudy() {
  const query = new URLSearchParams(location.search);
  const [layout, setLayout] = useState(directions.some(x => x.id === query.get('layout')) ? query.get('layout') : 'base');
  const [scene, setScene] = useState(['reader','map','notes'].includes(query.get('scene')) ? query.get('scene') : 'reader');
  const [small, setSmall] = useState(false), [details, setDetails] = useState(false);
  const [page, setPage] = useState(1), [zoom, setZoom] = useState('fit');
  const [menu, setMenu] = useState(null), [nav, setNav] = useState(false), [outline, setOutline] = useState(false), [ai, setAI] = useState(false);
  const [menuAnchor, setMenuAnchor] = useState(null);
  const [aiTab, setAITab] = useState('companion'), [outlineSide, setOutlineSide] = useState('left'), [aiSide, setAISide] = useState('right');
  const [draft, setDraft] = useState(''), [messages, setMessages] = useState([]), [search, setSearch] = useState('');
  const [note, setNote] = useState(initialNotes), [noteSaved, setNoteSaved] = useState(initialNotes), [notePreview, setNotePreview] = useState(true);
  const [tools, setTools] = useState(false), [quiet, setQuiet] = useState(false), [marking, setMarking] = useState(false);
  const [dock, setDock] = useState('center'), [railDock, setRailDock] = useState('center'), [dragDelta, setDragDelta] = useState(0);
  const [management, setManagement] = useState(null), [advanced, setAdvanced] = useState(false), [provider, setProvider] = useState('DeepSeek');
  const [modelDraft,setModelDraft] = useState({name:'我的 AI',modelID:'',output:8192});
  const [pluginQuery, setPluginQuery] = useState(''), [enabled, setEnabled] = useState(['map','mindmap','relations']);
  const [year, setYear] = useState(208), [event, setEvent] = useState('赤壁之战'), [notice, setNotice] = useState('');
  const frame = useRef(null), scroll = useRef(null), cluster = useRef(null), dockGesture = useRef(null), suppressDockClick = useRef(false), idle = useRef(null), toast = useRef(null);
  const focusBlockers = useRef(false);
  focusBlockers.current = ai || outline || nav || menu || management || tools;
  const [size, setSize] = useState({ w: 1280, h: 760 });
  const direction = directions.find(x => x.id === layout), bookTitle = scene === 'map' ? '三国演义' : '线性代数';
  useLayoutEffect(() => {
    const measure = () => { const r = frame.current.getBoundingClientRect(); setSize(old => old.w === r.width && old.h === r.height ? old : { w: r.width, h: r.height }); };
    measure(); const observer = new ResizeObserver(measure); observer.observe(frame.current); return () => observer.disconnect();
  }, []);
  useEffect(() => {
    const url = new URL(location.href); url.searchParams.set('layout',layout); url.searchParams.set('scene',scene); history.replaceState(null,'',url);
    setMenu(null); setQuiet(false); setTools(false); clearTimeout(idle.current);
  }, [layout,scene]);
  useEffect(() => () => { clearTimeout(idle.current); clearTimeout(toast.current); }, []);
  useEffect(() => {
    const key = e => {
      if (e.key === 'Escape') { setQuiet(false); setMenu(null); setManagement(null); setNav(false); setDetails(false); }
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'f') { e.preventDefault(); if (!management) reveal('outline',null,true); }
    };
    window.addEventListener('keydown', key); return () => window.removeEventListener('keydown', key);
  }, [size.w, aiSide, outlineSide, management]);
  useEffect(() => { clearTimeout(idle.current); if (focusBlockers.current) setQuiet(false); }, [ai, outline, nav, menu, management, tools]);
  useEffect(() => { if (size.w < 1000 && outline && ai) setOutline(false); }, [size.w, outline, ai]);
  useEffect(() => {
    if (quiet) frame.current?.focus({preventScroll:true});
    else clearTimeout(idle.current);
  }, [quiet]);
  useEffect(() => { setAISide('right'); setOutlineSide('left'); setDock('center'); setRailDock('center'); },[layout]);
  const notify = text => { setNotice(text); clearTimeout(toast.current); toast.current = setTimeout(() => setNotice(''), 2500); };
  function reveal(which, tab, force = false) {
    setMenu(null); setQuiet(false); setNav(false);
    if (which === 'outline') { setOutline(x => force ? true : !x); if(force) requestAnimationFrame(()=>frame.current?.querySelector('input[aria-label="搜索目录与原文"]')?.focus()); if (size.w < 1000 || aiSide === outlineSide) setAI(false); }
    if (which === 'ai') { setAI(x => tab && aiTab !== tab ? true : !x); if (tab) setAITab(tab); if (size.w < 1000 || aiSide === outlineSide) setOutline(false); }
  }
  function movePanel(which, side) {
    if (which === 'outline') { setOutlineSide(side); if (aiSide === side) setAI(false); }
    else { setAISide(side); if (outlineSide === side) setOutline(false); }
  }
  function changePage(next) { setPage(clamp(next,1,3)); scroll.current?.scrollTo({top:0,behavior:'instant'}); setMenu(null); }
  function toggleMenu(id, target) {
    const r = frame.current.getBoundingClientRect(), anchor = target.getBoundingClientRect();
    const width = id==='pages'?306:284;
    const left = id==='pages'?(anchor.left+anchor.right)/2-r.left-width/2:anchor.right-r.left-width;
    setMenuAnchor({left:clamp(left,12,r.width-width-12),bottom:r.bottom-anchor.top+10});
    setMenu(x=>x===id?null:id); setQuiet(false); clearTimeout(idle.current);
  }
  function startCluster(e, kind='base') {
    if (e.button !== 0 || layout !== kind) return;
    suppressDockClick.current=false; dockGesture.current = { x:e.clientX,y:e.clientY }; (e.target.closest('button')||e.currentTarget).setPointerCapture(e.pointerId);
  }
  function dragCluster(e) { const g=dockGesture.current; if(g) setDragDelta(layout==='edge'?e.clientY-g.y:e.clientX-g.x); }
  function finishCluster(e) {
    const g=dockGesture.current; dockGesture.current=null; setDragDelta(0); if(!g)return;
    if(Math.abs(layout==='edge'?e.clientY-g.y:e.clientX-g.x)<6){if(layout!=='edge')toggleMenu('pages',e.currentTarget);return;}
    suppressDockClick.current=true;
    const r=frame.current.getBoundingClientRect();
    if(layout==='edge')setRailDock(e.clientY-r.top<r.height/3?'top':e.clientY-r.top>r.height*2/3?'bottom':'center');
    else setDock(e.clientX-r.left<r.width/3?'left':e.clientX-r.left>r.width*2/3?'right':'center');
  }
  const pageStepper = <><Control icon="chevronLeft" label="上一页" disabled={page===1} onClick={()=>changePage(page-1)}/><button className={`cs-page-number ${layout==='base'?'can-drag':''}`} aria-label={layout==='base'?'页码与停靠':'选择页码'} title={layout==='base'?'点击选页；拖动页码区移动整组工具':'选择页码'} onPointerDown={e=>startCluster(e)} onPointerMove={dragCluster} onPointerUp={finishCluster} onPointerCancel={()=>{dockGesture.current=null;setDragDelta(0);}} onClick={e=>{if(e.detail===0||layout!=='base')toggleMenu('pages',e.currentTarget);}}>{page}<span>/ 3</span></button><Control icon="chevronRight" label="下一页" disabled={page===3} onClick={()=>changePage(page+1)}/></>;
  const toolActions = <><Control icon="outline" label="目录与搜索" selected={outline} onClick={()=>reveal('outline')}/><Control icon="sparkle" label="伴读与对话" selected={ai} onClick={()=>reveal('ai')}/><span className="cs-divider"/><Control icon="highlight" label="高亮批注" selected={marking} onClick={()=>{setMarking(x=>!x);notify(marking?'已退出批注示例':'批注示例已打开，原 PDF 保持原宽度');}}/><Control icon="more" label="更多阅读工具" selected={menu==='tools'} onClick={e=>toggleMenu('tools',e.currentTarget)}/></>;
  const readingToolbar = scene==='map' ? <><Control icon="target" label="查看当前事件" onClick={()=>{setAI(true);setAITab('companion');}}/><Control icon="chat" label="与书对话" selected={ai&&aiTab==='chat'} onClick={()=>reveal('ai','chat')}/><span className="cs-divider"/><Control icon="plugins" label="本书组件" onClick={()=>{setManagement('plugins');setAdvanced(false);}}/></> : scene==='notes' ? <><Control label={notePreview?'编辑笔记':'预览笔记'} icon={notePreview?'edit':'eye'} selected={!notePreview} onClick={()=>setNotePreview(x=>!x)}/><Control label="保存示例笔记" icon="save" disabled={note===noteSaved} onClick={()=>{setNoteSaved(note);notify('已保存本次示例笔记');}}/><span className="cs-divider"/><Control label="伴读与对话" icon="sparkle" selected={ai} onClick={()=>reveal('ai','chat')}/></> : toolActions;
  function enterScene(next) { setScene(next); setNav(false); setOutline(false); setAI(false); setMenu(null); setManagement(null); }
  function chooseNav(id) {
    if(['reader','map','notes'].includes(id)){enterScene(id);return;}
    if(id==='query'){setNav(false);setAI(true);setAITab('chat');return;}
    setNav(false); setManagement(id); setAdvanced(false);
  }
  function send() {
    if(!draft.trim())return;
    setMessages(old=>[...old,{question:draft.trim(),answer:scene==='map'?'先看这一时刻的事件、人物与地点，再核对原文。当前仅展示交互示例，没有调用模型。':'把参数代回原式，可以检验这个解是否成立。注意：自由变量存在时，解集可能是一条直线。当前为交互示例，没有调用模型。'}]);setDraft('');
  }
  const navItems = [['reader','原文阅读','reader'],['workflow','智能阅读','sparkle'],['query','与书对话','chat'],['notes','我的笔记','notes'],['map','时间与地图','map'],['mindmap','思维导图','mindmap'],['relations','关系图谱','relations'],['knowledge','知识库','knowledge'],['plugins','插件与组件','plugins'],['models','模型设置','models']];
  const glassStyle = { '--cs-width':`${size.w}px`, '--cs-height':`${size.h}px` };
  return <div className="cs-root">
    <div className="cs-study-bar"><div className="cs-study-brand"><Icon name="reader" size={22}/><strong>阅读界面 · 三种组织方式</strong></div><div className="cs-choices" role="group" aria-label="布局方案">{directions.map((x,i)=><button key={x.id} className={layout===x.id?'selected':''} aria-pressed={layout===x.id} onClick={()=>setLayout(x.id)}><small>{String(i+1).padStart(2,'0')}</small>{x.name}</button>)}</div><div className="cs-study-options"><label>场景<select aria-label="场景" value={scene} onChange={e=>enterScene(e.target.value)}><option value="reader">原文阅读</option><option value="map">时间与地图</option><option value="notes">我的笔记</option></select></label><button aria-pressed={small} onClick={()=>setSmall(x=>!x)}>{small?'恢复大小':'小窗'}</button><button aria-expanded={details} onClick={()=>setDetails(x=>!x)}>设计说明</button></div></div>
    {details&&<div className="cs-design-detail"><b>{direction.name}</b><span>{direction.detail}</span><small>面板仅一枚功能图标；按标题拖动，不再增加拖柄。完整功能保留在分组菜单中。</small></div>}
    <div className={`cs-preview-wrap ${small?'is-small':''}`}><main ref={frame} tabIndex={-1} className={`cs-frame ${size.w<1000?'is-compact':''} cs-layout-${layout} ${quiet?'is-quiet':''} ${tools?'tools-open':''} ${ai?'ai-open':''} ${outline?'outline-open':''}`} style={glassStyle} onPointerMove={e=>{if(layout==='focus'&&quiet){const r=frame.current.getBoundingClientRect();if(e.clientY-r.top>r.height-88||e.clientY-r.top<66)setQuiet(false);}}}>
      <div className="cs-traffic" aria-hidden="true"><i/><i/><i/></div>
      <div className="cs-top-cluster cs-glass" inert={quiet?true:undefined} aria-hidden={quiet?true:undefined}><Control icon="sidebar" label="展开导航" selected={nav} onClick={()=>{setNav(x=>!x);setOutline(false);setMenu(null);setQuiet(false);}}/><span className="cs-divider"/><button className="cs-book-button" aria-expanded={menu==='book'} aria-label="图书与工作区菜单" onClick={()=>setMenu(x=>x==='book'?null:'book')}><Icon name="book" size={18}/><span>{bookTitle}</span><Icon name="chevronDown" size={13}/></button></div>
      <div className="cs-top-action" inert={quiet?true:undefined} aria-hidden={quiet?true:undefined}><Control icon="sparkle" className="cs-primary" label="智能阅读" onClick={()=>{setManagement('workflow');setAdvanced(false);}}>智能阅读</Control></div>
      <div className="cs-content-scroll" ref={scroll} onScroll={()=>{
        if(layout!=='focus'||ai||outline||nav||menu||management||tools)return;
        clearTimeout(idle.current); idle.current=setTimeout(()=>{if(!focusBlockers.current&&!document.activeElement?.matches('input,textarea,select,[contenteditable=true]'))setQuiet(true);},1400);
      }}>
        {scene==='reader'&&<div className="cs-paper"><SamplePage page={page} zoom={zoom}/></div>}
        {scene==='map'&&<div className="cs-map"><img src="/assets/map-terrain.png" alt="历史阅读示例地形，非考据地图"/><div className="cs-map-place place-one"><span>江夏</span><button onClick={()=>{setEvent('江夏相会');setAI(true);setAITab('companion');}}>江夏相会</button></div><div className="cs-map-place place-two"><span>赤壁</span><button onClick={()=>{setEvent('赤壁之战');setAI(true);setAITab('companion');}} className={event==='赤壁之战'?'selected':''}>赤壁之战</button></div><div className="cs-map-place place-three"><span>江陵</span><button onClick={()=>{setEvent('江陵之争');setYear(209);setAI(true);setAITab('companion');}}>江陵之争</button></div><div className="cs-time-card cs-glass"><div><Icon name="clock" size={18}/><strong>{year} 年</strong><span>{event}</span></div><input aria-label="当前年份" type="range" min="208" max="210" value={year} onChange={e=>setYear(Number(e.target.value))}/></div></div>}
        {scene==='notes'&&<article className="cs-note-paper"><div className="cs-note-meta"><span><Icon name="notes" size={17}/>我的笔记</span><small>{note===noteSaved?'已保存示例':'未保存'}</small></div>{notePreview?<Markdown text={note}/>:<textarea className="cs-note-editor" aria-label="笔记 Markdown" value={note} onChange={e=>setNote(e.target.value)}/>}</article>}
      </div>
      {layout==='base'&&<div ref={cluster} className={`cs-bottom-base cs-glass dock-${dock} ${dragDelta?'is-moving':''}`} style={dragDelta?{translate:`${dragDelta}px 0`}:undefined}>{scene==='reader'&&<><div className="cs-pages">{pageStepper}</div><span className="cs-divider"/></>}{readingToolbar}</div>}
      {layout==='edge'&&<><div className={`cs-edge-dock cs-glass rail-${railDock} ${dragDelta?'is-moving':''}`} style={dragDelta?{translate:`0 ${dragDelta}px`}:undefined} onPointerDown={e=>startCluster(e,'edge')} onPointerMove={dragCluster} onPointerUp={finishCluster} onPointerCancel={()=>{dockGesture.current=null;suppressDockClick.current=false;setDragDelta(0);}} onClickCapture={e=>{if(suppressDockClick.current){e.preventDefault();e.stopPropagation();suppressDockClick.current=false;}}} title="拖动整组工具，沿右侧吸附">{readingToolbar}</div>{scene==='reader'&&<div className="cs-page-capsule cs-glass">{pageStepper}</div>}</>}
      {layout==='focus'&&<div className={`cs-focus-tools cs-glass ${tools?'expanded':''}`} inert={quiet?true:undefined} aria-hidden={quiet?true:undefined}>{scene==='reader'&&<><div className="cs-pages">{pageStepper}</div><span className="cs-divider"/></>}<Control icon={tools?'minus':'more'} label={tools?'收起阅读工具':'展开阅读工具'} selected={tools} onClick={()=>{setTools(x=>!x);setQuiet(false);}}>{scene!=='reader'&&!tools?'工具':null}</Control>{tools&&<><span className="cs-divider"/>{readingToolbar}<Control icon="eyeOff" label="进入沉浸模式" onClick={()=>{setTools(false);setQuiet(true);setMenu(null);setAI(false);setOutline(false);}}/></>}</div>}
      {menu==='book'&&<Popover className="cs-book-menu" close={()=>setMenu(null)}><MenuRow icon="book" checked detail={scene==='map'?'历史阅读示例':'PDF · 3 页'}>{bookTitle}</MenuRow><div className="cs-menu-divider"/><MenuRow icon="library" onClick={()=>{setManagement('library');setMenu(null);}}>书库</MenuRow><MenuRow icon="plus" onClick={()=>notify('此处为导入入口演示，不读取你的文件')}>导入图书</MenuRow><div className="cs-menu-divider"/><MenuRow icon="models" detail={provider+' · 示例'} onClick={()=>{setManagement('models');setMenu(null);}}>AI 服务</MenuRow><MenuRow icon="plugins" onClick={()=>{setManagement('plugins');setMenu(null);}}>本书组件</MenuRow><MenuRow icon="refresh" onClick={()=>{setDock('center');setRailDock('center');setOutlineSide('left');setAISide('right');setMenu(null);notify('已恢复示例布局，草稿保留');}}>重置布局</MenuRow></Popover>}
      {menu==='tools'&&<Popover style={menuAnchor} className="cs-tool-menu" close={()=>setMenu(null)}><div className="cs-menu-caption">阅读工具</div><MenuRow icon="reader" checked>原始 PDF</MenuRow><MenuRow icon="file" onClick={()=>{notify('识别稿入口保留；此交互稿不调用 OCR');setMenu(null);}}>识别稿</MenuRow><div className="cs-menu-divider"/><label className="cs-menu-field">缩放<select aria-label="阅读缩放" value={zoom} onChange={e=>setZoom(e.target.value)}><option value="fit">适合宽度</option><option value="100">100%</option><option value="125">125%</option></select></label><MenuRow icon="notes" onClick={()=>{enterScene('notes');}}>我的笔记</MenuRow><MenuRow icon="models" onClick={()=>{setManagement('models');setMenu(null);}}>模型设置</MenuRow></Popover>}
      {menu==='pages'&&<Popover style={menuAnchor} className="cs-page-menu" close={()=>setMenu(null)}><div className="cs-menu-caption">跳到页面</div>{sections.map((x,i)=><MenuRow key={x} icon="file" checked={page===i+1} onClick={()=>changePage(i+1)}><span>{i+1}　{x}</span></MenuRow>)}</Popover>}
      <StudyPanel open={nav} title="阅读工作台" icon="reader" side="left" close={()=>setNav(false)} frame={frame}>
        <div className="cs-navigation">{navItems.map(([id,label,icon])=><MenuRow key={id} icon={icon} checked={scene===id} onClick={()=>chooseNav(id)}>{label}</MenuRow>)}</div>
      </StudyPanel>
      <StudyPanel open={outline} title={scene==='notes'?'笔记':'目录与搜索'} icon={scene==='notes'?'notes':'outline'} side={outlineSide} close={()=>setOutline(false)} draggable={layout==='base'} onDock={side=>movePanel('outline',side)} frame={frame}>
        <label className="cs-panel-search"><Icon name="search" size={18}/><input aria-label="搜索目录与原文" placeholder="搜索目录与原文" value={search} onChange={e=>setSearch(e.target.value)}/>{search&&<Control icon="close" label="清空搜索" onClick={()=>setSearch('')}/>}</label><div className="cs-chapter-list">{sections.filter(x=>!search||x.includes(search)).map(x=>{const index=sections.indexOf(x);return <button key={x} className={page===index+1?'selected':''} onClick={()=>changePage(index+1)}><small>{String(index+1).padStart(2,'0')}</small><span>{x}<small>第 {index+1} 页</small></span>{page===index+1&&<Icon name="check" size={16}/>}</button>;})}{search&&!sections.some(x=>x.includes(search))&&<p className="cs-empty">没有匹配的章节</p>}</div>
      </StudyPanel>
      <StudyPanel open={ai} title={scene==='map'?'人物与事件':'伴读与对话'} icon="sparkle" side={aiSide} close={()=>setAI(false)} draggable={layout==='base'} onDock={side=>movePanel('ai',side)} frame={frame}>
        <div className="cs-ai-tabs" role="group" aria-label="AI 面板内容"><button aria-pressed={aiTab==='companion'} onClick={()=>setAITab('companion')}>伴读</button><button aria-pressed={aiTab==='chat'} onClick={()=>setAITab('chat')}>对话</button></div>
        <div className="cs-ai-scroll">{aiTab==='companion'?<><div className="cs-context-label">{scene==='map'?`${year} 年 · ${event}`:`当前页 · 第 ${page} 页`}</div><h3>{scene==='map'?event:'从一个条件，理解一整段推导。'}</h3><Markdown text={scene==='map'?'先对齐事件、人物和地点，再沿同一时间轴观察变化。\n\n年代或地点没有依据时，保留未知。':String.raw`主元决定被约束的变量，自由变量决定解集如何展开。

$$x_3=t\quad\Longrightarrow\quad x_1=2-t,\quad x_2=1+2t$$

把一个具体的 $t$ 代回原式，可以验证你是否真的理解了这个解集。`}/><button className="cs-source-link" onClick={()=>{changePage(3);notify('已定位到示例原文');}}>查看原文依据<Icon name="chevronRight" size={15}/></button><Control icon="chat" className="cs-inline-action" onClick={()=>setAITab('chat')}>围绕这里提问</Control></>:<>{messages.length===0?<div className="cs-chat-empty"><Icon name="chat" size={27}/><h3>顺着问题，读得更深。</h3></div>:messages.map((x,i)=><div className="cs-message" key={i}><p className="cs-user-message">{x.question}</p><small>示例回答</small><p>{x.answer}</p><button className="cs-source-link" onClick={()=>{setNote(n=>n+'\n\n## 一次阅读对话\n\n'+x.answer);notify('已加入示例笔记，尚未保存');}}>保存到笔记<Icon name="notes" size={15}/></button></div>)}</>}</div>
        {aiTab==='chat'&&<div className="cs-composer"><div><select aria-label="提问范围"><option>当前页</option><option>当前章</option><option>整本书</option></select><Control icon="plus" label="附加笔记" onClick={()=>notify('已选择本次示例笔记作为附加内容')}/></div><textarea aria-label="对话草稿" placeholder="问一个问题…" value={draft} onChange={e=>setDraft(e.target.value)}/><Control icon="arrowRight" className="cs-send" label="发送演示提问" disabled={!draft.trim()} onClick={send}/></div>}
      </StudyPanel>
      {management&&<ManagementLayer close={()=>setManagement(null)}><section className="cs-management cs-glass" role="dialog" aria-modal="true" aria-label={management==='models'?'模型设置':management==='plugins'?'插件与组件':management==='workflow'?'智能阅读':'工作区预览'}><header><Icon name={management==='models'?'models':management==='plugins'?'plugins':management==='workflow'?'sparkle':'library'} size={21}/><h2>{management==='models'?'模型设置':management==='plugins'?'插件与组件':management==='workflow'?'智能阅读':'工作区预览'}</h2><Control icon="close" label="关闭管理面板" onClick={()=>setManagement(null)}/></header><div className="cs-management-body">
        {management==='models'?<><label>已保存服务<select value={provider} onChange={e=>setProvider(e.target.value)}><option>DeepSeek</option><option>OpenAI</option><option>自定义服务</option></select></label><label>服务名称<input value={modelDraft.name} onChange={e=>setModelDraft(x=>({...x,name:e.target.value}))}/></label><label>模型 ID<input placeholder="选择或输入模型 ID" value={modelDraft.modelID} onChange={e=>setModelDraft(x=>({...x,modelID:e.target.value}))}/></label><div className="cs-output-row"><label>输出额度<input type="number" value={modelDraft.output} onChange={e=>setModelDraft(x=>({...x,output:e.target.value}))}/></label><Control disabled title="需先在完整设置中选择已核实型号">Max</Control></div><button className="cs-disclosure" aria-expanded={advanced} onClick={()=>setAdvanced(x=>!x)}><Icon name={advanced?'minus':'plus'} size={16}/>模型规格与高级设置</button>{advanced&&<p className="cs-secondary">上下文、视觉能力、温度和供应商参数集中在此。未知规格明确标为未知，不能因点 Max 而推测。</p>}</>:management==='plugins'?<><label className="cs-panel-search"><Icon name="search" size={18}/><input placeholder="搜索组件" aria-label="搜索组件" value={pluginQuery} onChange={e=>setPluginQuery(e.target.value)}/></label>{[['map','时间与地图'],['mindmap','思维导图'],['relations','关系图谱']].filter(([,name])=>name.includes(pluginQuery)).map(([id,name])=><label className="cs-plugin-row" key={id}><Icon name={id} size={23}/><span>{name}</span><input type="checkbox" checked={enabled.includes(id)} onChange={()=>setEnabled(xs=>xs.includes(id)?xs.filter(x=>x!==id):[...xs,id])}/></label>)}<button className="cs-disclosure" aria-expanded={advanced} onClick={()=>setAdvanced(x=>!x)}><Icon name={advanced?'minus':'plus'} size={16}/>类型、阅读方法与高级定义</button>{advanced&&<><label>类型名称<input defaultValue="概念"/></label><label>字段<input defaultValue="定义、条件、原文出处"/></label><details><summary>执行绑定</summary><p className="cs-secondary">接口与版本信息只在需要编辑时展开。</p></details></>}</>:management==='workflow'?<><h3>这本书，怎样读？</h3><button className="cs-smart-choice selected"><Icon name="sparkle" size={22}/><span>让 AI 决定<small>先预读，再确认方法与范围</small></span><Icon name="check" size={18}/></button><label>分析范围<select><option>当前页</option><option>当前章</option><option>整本书</option></select></label></>:<><p>布局方案也适用于地图、笔记和其他组件。此处不重复完整软件功能。</p><div className="cs-scene-links"><Control icon="reader" onClick={()=>enterScene('reader')}>阅读</Control><Control icon="map" onClick={()=>enterScene('map')}>地图</Control><Control icon="notes" onClick={()=>enterScene('notes')}>笔记</Control></div><a href="/?book=history#reader" target="_blank" rel="noreferrer">打开完整软件交互稿</a></>}
      </div>{['models','plugins','workflow'].includes(management)&&<footer><Control className="cs-primary" icon={management==='workflow'?'sparkle':'save'} onClick={()=>{notify(management==='workflow'?'已展示预读入口；没有调用真实 AI':'已保存本次界面示例');setManagement(null);}}>{management==='workflow'?'预读方案':'保存'}</Control></footer>}</section></ManagementLayer>}
      {notice&&<div className="cs-notice" role="status">{notice}</div>}
      {quiet&&<span className="cs-quiet-hint">Esc 或移到下缘，唤回工具</span>}
    </main></div>
    <div className="cs-study-foot"><span><b>{direction.name}</b> · {scene==='reader'?direction.short:scene==='map'?'同一套工具规则，一根时间轴。':'同一套工具规则，保留笔记正文。'}</span><small>交互实验 · 示例 PDF / 内容 · 不调用 AI，不修改你的书和笔记</small></div>
  </div>;
}
