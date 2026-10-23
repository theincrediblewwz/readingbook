import React,{useCallback,useEffect,useMemo,useRef,useState} from 'react';
import {AppContext,Button,Icon,Modal} from './shared.jsx';
import {books,initialState} from './data.js';
import {ReaderPage,LibraryPage,ObjectsPage,ParallelPage,PrintSample} from './pages/Reader.jsx';
import {MapPage,MindmapPage,RelationsPage} from './pages/Spatial.jsx';
import {NotesPage,ChatPage,KnowledgePage,SearchPanel,TrashPage} from './pages/Notes.jsx';
import {PluginsPage,ModelsPage,WorkflowPage} from './pages/Settings.jsx';
import {LayersPage} from './pages/ReadingExperience.jsx';
import './styles.css';
import './fidelity.css';
const routes={library:'书库',reader:'原文阅读',parallel:'译注对照',layers:'已有伴读',workflow:'读书方法',chat:'与书对话',notes:'我的笔记',map:'时间与地图',mindmap:'思维导图',relations:'关系图谱',knowledge:'知识库',atlas:'全书总览',cards:'要素卡片',plugins:'插件与组件',models:'模型设置',trash:'回收站'};
const componentForRoute={map:'spatial',mindmap:'mindmap',relations:'relations',knowledge:'knowledge',cards:'cards',atlas:'atlas'};
const pages={library:LibraryPage,reader:ReaderPage,parallel:ParallelPage,layers:LayersPage,workflow:WorkflowPage,chat:ChatPage,notes:NotesPage,map:MapPage,mindmap:MindmapPage,relations:RelationsPage,knowledge:KnowledgePage,atlas:ObjectsPage,cards:ObjectsPage,plugins:PluginsPage,models:ModelsPage,trash:TrashPage};
function NavigationHandle({onOpen}){
  const [dock,setDock]=useState(()=>sessionStorage.getItem('prototype-nav-dock')||'bottom'),[dragY,setDragY]=useState(null),[height,setHeight]=useState(innerHeight),gesture=useRef(null);
  useEffect(()=>{sessionStorage.setItem('prototype-nav-dock',dock);document.documentElement.dataset.navigationDock=dock;},[dock]);
  useEffect(()=>{const resize=()=>{setHeight(innerHeight);gesture.current=null;setDragY(null);};addEventListener('resize',resize);return()=>removeEventListener('resize',resize);},[]);
  const clamp=y=>Math.max(72,Math.min(y,Math.max(72,height-48))),y=dragY??(dock==='top'?72:Math.max(72,height-48));
  return <button className="nav-handle glass" style={{top:y-24}} aria-label="展开导航" title="展开导航 · 拖动到左上或左下 · ⌘/Ctrl B" onPointerDown={e=>{if(e.button!==0)return;gesture.current={start:e.clientY,y,moved:false};e.currentTarget.setPointerCapture(e.pointerId);}} onPointerMove={e=>{const g=gesture.current;if(!g)return;if(Math.abs(e.clientY-g.start)>5)g.moved=true;if(g.moved)setDragY(clamp(g.y+e.clientY-g.start));}} onPointerUp={e=>{const g=gesture.current;if(!g)return;gesture.current=null;setDragY(null);if(g.moved){const p=clamp(g.y+e.clientY-g.start);setDock(Math.abs(p-72)<Math.abs(p-(height-48))?'top':'bottom');}else onOpen();}} onPointerCancel={()=>{gesture.current=null;setDragY(null);}} onClick={e=>{if(e.detail===0)onOpen();}}><Icon name="sidebar" size={23}/><em className="nav-tip">展开导航</em></button>;
}
function startingState(){const url=new URL(location.href),route=url.searchParams.get('route')||location.hash.slice(1),bookId=url.searchParams.get('book');return {...initialState,route:pages[route]?route:'reader',currentBookId:books.some(b=>b.id===bookId)?bookId:'math',selectedDocId:bookId==='history'?'h-fire':'math-note'};}
export function App(){
  const [state,setState]=useState(startingState),stateRef=useRef(state);stateRef.current=state;
  const [nav,setNav]=useState(false),[menu,setMenu]=useState(null),[toast,setToast]=useState(''),[confirmation,setConfirmation]=useState(null),[about,setAbout]=useState(false);
  const toastTimer=useRef(null),guards=useRef(new Set()),confirmResolver=useRef(null);
  const update=useCallback(patch=>setState(prev=>typeof patch==='function'?patch(prev):{...prev,...patch}),[]);
  const notify=useCallback(text=>{clearTimeout(toastTimer.current);setToast(text);toastTimer.current=setTimeout(()=>setToast(''),3600);},[]);
  useEffect(()=>()=>clearTimeout(toastTimer.current),[]);
  const registerGuard=useCallback(fn=>{guards.current.add(fn);return()=>guards.current.delete(fn);},[]);
  const navigate=useCallback(async(route,payload={})=>{if(!pages[route])return false;setNav(false);setMenu(null);for(const guard of [...guards.current]){if(!await guard(route,payload))return false;}update(prev=>({...prev,route,...payload}));history.replaceState(null,'','#'+route);return true;},[update]);
  const confirm=useCallback(options=>new Promise(resolve=>{confirmResolver.current=resolve;setConfirmation(options);}),[]);
  const settle=value=>{confirmResolver.current?.(value);confirmResolver.current=null;setConfirmation(null);};
  const book=books.find(b=>b.id===state.currentBookId)||books[0];
  const activeProfile=state.profiles.find(p=>p.id===state.activeProfileId)||state.profiles[0];
  useEffect(()=>{function key(e){if(e.key==='Escape'){setNav(false);setMenu(null);}if(!(e.metaKey||e.ctrlKey))return;const route={'1':'reader','2':'workflow','3':'chat','4':'notes'}[e.key];if(route){e.preventDefault();navigate(route);}if(e.key.toLowerCase()==='f'){e.preventDefault();update({searchOpen:true});}if(e.key.toLowerCase()==='b'){e.preventDefault();setNav(v=>!v);}}window.addEventListener('keydown',key);return()=>window.removeEventListener('keydown',key);},[navigate,update]);
  const value=useMemo(()=>({state,update,navigate,notify,confirm,registerGuard,book}),[state,update,navigate,notify,confirm,registerGuard,book]);
  if(new URL(location.href).searchParams.has('print'))return <PrintSample/>;
  const Page=pages[state.route]||ReaderPage;
  const primaryLabel={reader:state.workflow.status==='running'?'查看精读':'继续精读',library:'导入一本书',workflow:'调整读法',notes:'保存',map:'回到原文',parallel:'回到原文',relations:'回到原文',mindmap:'新建笔记',chat:'新建对话',knowledge:'新建笔记',plugins:'导入插件',models:'保存配置',trash:'返回书库',cards:'添加要素',atlas:'回到原文'}[state.route];
  async function primary(){
    if(state.route==='workflow'){window.dispatchEvent(new CustomEvent('prototype-method-open'));return;}
    if(state.route==='reader'){await navigate('workflow');return;}
    if(['map','relations','atlas','parallel'].includes(state.route)){navigate('reader');return;}
    if(state.route==='trash'){navigate('library');return;}
    if(['mindmap','knowledge'].includes(state.route)){await navigate('notes',{noteDraftRequest:{bookId:state.currentBookId}});return;}
    window.dispatchEvent(new CustomEvent('prototype-primary'));
  }
  const title=['models','plugins','library','trash'].includes(state.route)?routes[state.route]:book.title;
  return <AppContext.Provider value={value}><main className="app-shell" data-route={state.route}>
    <div className="workspace"><Page/></div>
    <div className="traffic-lights" aria-hidden="true"><i/><i/><i/></div>
    <header className="top-islands"><button className="book-island glass" aria-label="选择图书" aria-expanded={menu==='book'} onClick={()=>setMenu(menu==='book'?null:'book')}><img src="/assets/book-mark.svg" alt=""/><span>{title}</span><Icon name="chevronDown" size={16}/></button><div className="top-spacer"/><button className="service-island glass" aria-label="选择AI服务" aria-expanded={menu==='service'} onClick={()=>setMenu(menu==='service'?null:'service')}><i className="status-dot"/>{activeProfile?.name||'选择服务'}<Icon name="chevronDown" size={15}/></button>{primaryLabel&&<Button className="top-primary" variant="primary" icon={state.route==='notes'||state.route==='models'?'save':state.route==='map'?'book':'sparkle'} onClick={primary}>{primaryLabel}</Button>}</header>
    {menu==='book'?<div className="glass popup-menu book-menu"><p>阅读中的图书</p>{books.filter(b=>!(state.deletedBookIds||[]).includes(b.id)).map(b=><button className={'nav-row '+(b.id===state.currentBookId?'selected':'')} key={b.id} onClick={()=>navigate('reader',{currentBookId:b.id,selectedDocId:b.id==='math'?'math-note':'h-main',page:1,source:null})}><Icon name="book"/>{b.title}</button>)}<hr/><button className="nav-row" onClick={()=>navigate('library')}><Icon name="library"/>打开书库</button></div>:null}
    {menu==='service'?<div className="glass popup-menu service-menu"><p>已保存的示例服务</p>{state.profiles.map(p=><button className={'nav-row '+(p.id===state.activeProfileId?'selected':'')} key={p.id} onClick={()=>{update({activeProfileId:p.id});setMenu(null);notify('已切换到 '+p.name+' 示例配置');}}><Icon name="link"/>{p.name}{p.id===state.activeProfileId?<small>当前</small>:null}</button>)}<hr/><button className="nav-row" onClick={()=>navigate('models')}><Icon name="models"/>管理与测试服务</button></div>:null}
    {!nav?<NavigationHandle onOpen={()=>{setNav(true);setMenu(null);}}/>:<nav className="glass navigation" aria-label="主导航" onWheel={e=>e.stopPropagation()}><header><strong>阅读工作台</strong><Button icon="close" aria-label="收起导航" variant="quiet" onClick={()=>setNav(false)}/></header>{Object.entries(routes).filter(([id])=>(id!=='parallel'||state.enabledPlugins.includes('parallel'))&&(!componentForRoute[id]||state.addedComponents.includes(componentForRoute[id]))).map(([id,label],i)=><React.Fragment key={id}>{[1,5,11,13].includes(i)?<div className="nav-divider"/>:null}<button className={'nav-row '+(state.route===id?'selected':'')} onClick={()=>navigate(id)} aria-current={state.route===id?'page':undefined}><Icon name={id}/><span>{label}</span></button></React.Fragment>)}<button className="nav-row" onClick={()=>navigate('plugins')}><Icon name="plus"/>添加组件</button><div className="nav-divider"/><button className="nav-row" onClick={()=>setAbout(true)}><Icon name="info"/>关于这份交互稿</button></nav>}
    <div id="panel-tray" className="panel-tray" aria-label="已关闭面板的恢复入口"/>
    {state.searchOpen?<SearchPanel/>:null}
    {toast?<div role="status" className="toast">{toast}</div>:null}
    <span className="demo-label">交互稿 · 示例数据 · 不连接真实 AI</span>
    {confirmation?<Modal title={confirmation.title||'确认操作'} onClose={()=>settle(false)} footer={<><Button onClick={()=>settle(false)}>取消</Button><Button variant={confirmation.danger?'danger':'primary'} onClick={()=>settle(true)}>{confirmation.confirmLabel||'确认'}</Button></>}><p>{confirmation.body}</p></Modal>:null}
    {about?<Modal title="关于这份交互稿" onClose={()=>setAbout(false)}><p>本稿用于评审全软件的视觉与操作。内容在当前页面的内存里演示，刷新后重置；下载的 Markdown 文件由你主动保存。</p><p>PDF 示例是真实的自编 PDF；地图为生成的地理布局示意。OCR、模型测试、精读与插件调用使用本地模拟，不证明识别或理解准确，不发起付费请求。</p><p>左侧的侧栏图标展开全软件导航，也可拖动到左上或左下。浮窗可拖动、收起、关闭；关闭后从右下方恢复。⌘/Ctrl F 搜索原文，⌘/Ctrl B 展开导航。</p><a href="/design/index.html" target="_blank" rel="noreferrer">查看页面效果稿与覆盖清单</a></Modal>:null}
  </main></AppContext.Provider>;
}
