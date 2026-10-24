import React,{useCallback,useEffect,useMemo,useRef,useState} from 'react';
import {AppContext,Button,Icon,Modal} from './shared.jsx';
import {books,initialState} from './data.js';
import {ReaderPage,LibraryPage,ObjectsPage,ParallelPage,PrintSample} from './pages/Reader.jsx';
import {MapPage,MindmapPage,RelationsPage} from './pages/Spatial.jsx';
import {NotesPage,ChatPage,KnowledgePage,SearchPanel,TrashPage} from './pages/Notes.jsx';
import {PluginsPage,ModelsPage} from './pages/Settings.jsx';
import {SmartReadingPage as WorkflowPage,SmartReadingProgress} from './pages/SmartReading.jsx';
import {LayersPage} from './pages/ReadingExperience.jsx';
import './styles.css';
import './fidelity.css';
import './floating.css';
import './polish.css';
import './base-workspace.css';
const routes={library:'书库',reader:'原文阅读',parallel:'译注对照',layers:'已有伴读',workflow:'智能阅读',chat:'与书对话',notes:'我的笔记',map:'时间与地图',mindmap:'思维导图',relations:'关系图谱',knowledge:'知识库',atlas:'全书总览',cards:'要素卡片',plugins:'插件与组件',models:'模型设置',trash:'回收站'};
const componentForRoute={map:'spatial',mindmap:'mindmap',relations:'relations',knowledge:'knowledge',cards:'cards',atlas:'atlas'};
const pages={library:LibraryPage,reader:ReaderPage,parallel:ParallelPage,layers:LayersPage,workflow:WorkflowPage,chat:ChatPage,notes:NotesPage,map:MapPage,mindmap:MindmapPage,relations:RelationsPage,knowledge:KnowledgePage,atlas:ObjectsPage,cards:ObjectsPage,plugins:PluginsPage,models:ModelsPage,trash:TrashPage};
function startingState(){const url=new URL(location.href),route=url.searchParams.get('route')||location.hash.slice(1),bookId=url.searchParams.get('book');return {...initialState,route:['plugins','models'].includes(route)?'reader':pages[route]?route:'reader',managementRoute:['plugins','models'].includes(route)?route:null,currentBookId:books.some(b=>b.id===bookId)?bookId:'math',selectedDocId:bookId==='history'?'h-fire':'math-note'};}
export function App(){
  const [state,setState]=useState(startingState),stateRef=useRef(state);stateRef.current=state;
  const [nav,setNav]=useState(false),[menu,setMenu]=useState(null),[toast,setToast]=useState(''),[confirmation,setConfirmation]=useState(null),[about,setAbout]=useState(false);
  const toastTimer=useRef(null),guards=useRef(new Set()),confirmResolver=useRef(null);
  const update=useCallback(patch=>setState(prev=>typeof patch==='function'?patch(prev):{...prev,...patch}),[]);
  const notify=useCallback(text=>{clearTimeout(toastTimer.current);setToast(text);toastTimer.current=setTimeout(()=>setToast(''),3600);},[]);
  useEffect(()=>()=>clearTimeout(toastTimer.current),[]);
  const registerGuard=useCallback(fn=>{
    const owned=Object.assign((...args)=>fn(...args),{workspace:stateRef.current.managementRoute||stateRef.current.route});
    guards.current.add(owned);return()=>guards.current.delete(owned);
  },[]);
  const navigate=useCallback(async(route,payload={})=>{
    if(!pages[route])return false;
    setNav(false);setMenu(null);update({readerNavigationOpen:false});
    const current=stateRef.current,managing=['models','plugins'].includes(route);
    if(managing&&!current.managementRoute){update({managementRoute:route});return true;}
    const returnsToPage=!!current.managementRoute&&route===current.route&&Object.keys(payload).length===0;
    for(const guard of [...guards.current]){
      // Closing or switching a management card leaves the underlying editor mounted.
      if(current.managementRoute&&(managing||returnsToPage)&&guard.workspace!==current.managementRoute)continue;
      if(!await guard(route,payload))return false;
    }
    if(managing){update({managementRoute:route});return true;}
    update(prev=>({...prev,managementRoute:null,route,...payload}));history.replaceState(null,'','#'+route);return true;
  },[update]);
  const confirm=useCallback(options=>new Promise(resolve=>{confirmResolver.current=resolve;setConfirmation(options);}),[]);
  const settle=value=>{confirmResolver.current?.(value);confirmResolver.current=null;setConfirmation(null);};
  const book=books.find(b=>b.id===state.currentBookId)||books[0];
  const activeProfile=state.profiles.find(p=>p.id===state.activeProfileId)||state.profiles[0];
  useEffect(()=>{function key(e){if(e.key==='Escape'){setNav(false);setMenu(null);update({readerNavigationOpen:false});}if(!(e.metaKey||e.ctrlKey))return;const route={'1':'reader','2':'workflow','3':'chat','4':'notes'}[e.key];if(route){e.preventDefault();navigate(route);}if(e.key.toLowerCase()==='f'){e.preventDefault();if(!stateRef.current.managementRoute)update({searchOpen:true});}if(e.key.toLowerCase()==='b'){e.preventDefault();if(!stateRef.current.managementRoute)setNav(v=>!v);}}window.addEventListener('keydown',key);return()=>window.removeEventListener('keydown',key);},[navigate,update]);
  const value=useMemo(()=>({state,update,navigate,notify,confirm,registerGuard,book}),[state,update,navigate,notify,confirm,registerGuard,book]);
  if(new URL(location.href).searchParams.has('print'))return <PrintSample/>;
  const Page=pages[state.route]||ReaderPage;
  const Overlay=state.managementRoute?pages[state.managementRoute]:null;
  const title=['models','plugins','library','trash'].includes(state.route)?routes[state.route]:book.title;
  return <AppContext.Provider value={value}><main className="app-shell" data-route={state.route} data-management={state.managementRoute||undefined}>
    <div className="workspace" inert={!!state.managementRoute}><Page/></div>
    {Overlay?<div className="management-overlay" role="dialog" aria-label={routes[state.managementRoute]}><Overlay/></div>:null}
    <div className="traffic-lights" aria-hidden="true"><i/><i/><i/></div>
    <header className="top-islands"><div className="top-left-cluster glass"><Button icon="sidebar" variant="quiet" aria-label="展开功能导航" title="功能导航" aria-expanded={nav} className={nav?'is-selected':''} onClick={()=>{setNav(v=>!v);setMenu(null);update({readerNavigationOpen:false});}}/>{state.route==='reader'?<Button icon="book" variant="quiet" aria-label="阅读导航" title="目录、缩略图、书签与查找" aria-expanded={!!state.readerNavigationOpen} className={state.readerNavigationOpen?'is-selected':''} disabled={state.demoLocked} onClick={()=>{update({readerNavigationOpen:!state.readerNavigationOpen});setNav(false);setMenu(null);}}/>:null}<i className="tool-divider"/><button className="book-island" aria-label="选择图书与服务" aria-expanded={menu==='book'} onClick={()=>{setMenu(menu==='book'?null:'book');setNav(false);update({readerNavigationOpen:false});}}><Icon name="book" size={20}/><span>{title}</span><Icon name="chevronDown" size={14}/></button></div><div className="top-spacer"/><Button className="top-primary" variant="primary" icon="sparkle" onClick={()=>navigate('workflow')}>{state.workflow.status==='running'?'查看分析':'智能阅读'}</Button></header>
    {(menu||nav)&&<button className="workspace-menu-dismiss" aria-label="关闭导航与菜单" onClick={()=>{setMenu(null);setNav(false);}}/>}
    {menu==='book'?<div className="glass popup-menu book-menu"><p>阅读中的图书</p>{books.filter(b=>!(state.deletedBookIds||[]).includes(b.id)).map(b=><button className={'nav-row '+(b.id===state.currentBookId?'selected':'')} key={b.id} onClick={()=>navigate('reader',{currentBookId:b.id,selectedDocId:b.id==='math'?'math-note':'h-main',page:1,source:null})}><Icon name="book"/>{b.title}</button>)}<hr/><button className="nav-row" onClick={()=>navigate('library')}><Icon name="library"/>打开书库</button><hr/><button className="nav-row" onClick={()=>setMenu('service')}><Icon name="models"/><span>{activeProfile?.name||'选择 AI 服务'}</span><Icon name="chevronRight" size={16}/></button><button className="nav-row" onClick={()=>navigate('plugins')}><Icon name="plugins"/>插件与组件</button></div>:null}
    {menu==='service'?<div className="glass popup-menu service-menu compact-service-menu"><header><Button variant="quiet" icon="chevronLeft" aria-label="返回图书与工作区" onClick={()=>setMenu('book')}/><h2>AI 服务</h2></header><div className="compact-service-list">{state.profiles.length?state.profiles.map(p=><button className={'compact-service-row '+(p.id===state.activeProfileId?'selected':'')} key={p.id} onClick={()=>{update({activeProfileId:p.id});setMenu(null);notify('已切换到 '+p.name+' 示例配置');}}><Icon name="link"/><span><strong>{p.name}</strong><small>{p.modelId||'尚未配置模型'}</small></span>{p.id===state.activeProfileId?<Icon name="check" size={17}/>:null}</button>):<p>尚未保存服务</p>}</div><footer><Button icon="models" variant="quiet" onClick={()=>navigate('models')}>管理服务</Button><Button icon="play" variant="quiet" disabled={!activeProfile?.modelId} onClick={()=>notify('连接测试为交互演示，未发起真实请求。')}>测试连接</Button></footer></div>:null}
    {nav?<nav className="glass navigation" aria-label="主导航" onWheel={e=>e.stopPropagation()}><header><strong>阅读工作台</strong><Button icon="close" aria-label="收起导航" variant="quiet" onClick={()=>setNav(false)}/></header>{Object.entries(routes).filter(([id])=>(id!=='parallel'||state.enabledPlugins.includes('parallel'))&&(!componentForRoute[id]||state.addedComponents.includes(componentForRoute[id]))).map(([id,label],i)=><React.Fragment key={id}>{[1,5,11,13].includes(i)?<div className="nav-divider"/>:null}<button className={'nav-row '+(state.route===id?'selected':'')} onClick={()=>navigate(id)} aria-current={state.route===id?'page':undefined}><Icon name={id}/><span>{label}</span></button></React.Fragment>)}<button className="nav-row" onClick={()=>navigate('plugins')}><Icon name="plus"/>添加组件</button><div className="nav-divider"/><button className="nav-row" onClick={()=>setAbout(true)}><Icon name="info"/>关于这份交互稿</button></nav>:null}
    {!state.managementRoute&&<SmartReadingProgress/>}
    <div id="panel-tray" className="panel-tray" aria-label="已关闭面板的恢复入口"/>
    {state.searchOpen&&state.route!=='reader'?<SearchPanel/>:null}
    {toast?<div role="status" className="toast">{toast}</div>:null}
    <span className="demo-label">交互稿 · 示例数据 · 不连接真实 AI</span>
    {confirmation?<Modal title={confirmation.title||'确认操作'} onClose={()=>settle(false)} footer={<><Button onClick={()=>settle(false)}>取消</Button><Button variant={confirmation.danger?'danger':'primary'} onClick={()=>settle(true)}>{confirmation.confirmLabel||'确认'}</Button></>}><p>{confirmation.body}</p></Modal>:null}
    {about?<Modal title="关于这份交互稿" onClose={()=>setAbout(false)}><p>本稿用于评审全软件的视觉与操作。内容在当前页面的内存里演示，刷新后重置；下载的 Markdown 文件由你主动保存。</p><p>PDF 示例是真实的自编 PDF；地图为生成的地理布局示意。OCR、模型测试、精读与插件调用使用本地模拟，不证明识别或理解准确，不发起付费请求。</p><p>左上角的侧栏图标展开全软件导航。浮窗可拖动、收起、关闭；阅读、地图、导图与笔记从各自底座恢复面板。⌘/Ctrl F 搜索原文，⌘/Ctrl B 展开导航。</p><a href="/design/index.html" target="_blank" rel="noreferrer">查看页面效果稿与覆盖清单</a></Modal>:null}
  </main></AppContext.Provider>;
}
