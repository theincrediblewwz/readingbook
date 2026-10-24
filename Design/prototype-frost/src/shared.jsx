import React,{createContext,useContext,useEffect,useLayoutEffect,useRef,useState,useCallback,useMemo} from 'react';
import {createPortal} from 'react-dom';
import {ListBulletsIcon} from '@phosphor-icons/react/dist/csr/ListBullets';
import {BookOpenIcon} from '@phosphor-icons/react/dist/csr/BookOpen';
import {BooksIcon} from '@phosphor-icons/react/dist/csr/Books';
import {GitBranchIcon} from '@phosphor-icons/react/dist/csr/GitBranch';
import {ChatCircleTextIcon} from '@phosphor-icons/react/dist/csr/ChatCircleText';
import {NotePencilIcon} from '@phosphor-icons/react/dist/csr/NotePencil';
import {MapPinIcon} from '@phosphor-icons/react/dist/csr/MapPin';
import {TreeStructureIcon} from '@phosphor-icons/react/dist/csr/TreeStructure';
import {GraphIcon} from '@phosphor-icons/react/dist/csr/Graph';
import {DatabaseIcon} from '@phosphor-icons/react/dist/csr/Database';
import {SquaresFourIcon} from '@phosphor-icons/react/dist/csr/SquaresFour';
import {PuzzlePieceIcon} from '@phosphor-icons/react/dist/csr/PuzzlePiece';
import {SlidersHorizontalIcon} from '@phosphor-icons/react/dist/csr/SlidersHorizontal';
import {TrashIcon} from '@phosphor-icons/react/dist/csr/Trash';
import {MagnifyingGlassIcon} from '@phosphor-icons/react/dist/csr/MagnifyingGlass';
import {PlusIcon} from '@phosphor-icons/react/dist/csr/Plus';
import {MinusIcon} from '@phosphor-icons/react/dist/csr/Minus';
import {XIcon} from '@phosphor-icons/react/dist/csr/X';
import {CaretLeftIcon} from '@phosphor-icons/react/dist/csr/CaretLeft';
import {CaretRightIcon} from '@phosphor-icons/react/dist/csr/CaretRight';
import {CaretDownIcon} from '@phosphor-icons/react/dist/csr/CaretDown';
import {DotsThreeIcon} from '@phosphor-icons/react/dist/csr/DotsThree';
import {CornersOutIcon} from '@phosphor-icons/react/dist/csr/CornersOut';
import {DotsSixIcon} from '@phosphor-icons/react/dist/csr/DotsSix';
import {CheckCircleIcon} from '@phosphor-icons/react/dist/csr/CheckCircle';
import {WarningCircleIcon} from '@phosphor-icons/react/dist/csr/WarningCircle';
import {InfoIcon} from '@phosphor-icons/react/dist/csr/Info';
import {FloppyDiskIcon} from '@phosphor-icons/react/dist/csr/FloppyDisk';
import {DownloadSimpleIcon} from '@phosphor-icons/react/dist/csr/DownloadSimple';
import {UploadSimpleIcon} from '@phosphor-icons/react/dist/csr/UploadSimple';
import {LinkIcon} from '@phosphor-icons/react/dist/csr/Link';
import {EyeIcon} from '@phosphor-icons/react/dist/csr/Eye';
import {EyeSlashIcon} from '@phosphor-icons/react/dist/csr/EyeSlash';
import {PlayIcon} from '@phosphor-icons/react/dist/csr/Play';
import {PauseIcon} from '@phosphor-icons/react/dist/csr/Pause';
import {ArrowClockwiseIcon} from '@phosphor-icons/react/dist/csr/ArrowClockwise';
import {ArrowUUpLeftIcon} from '@phosphor-icons/react/dist/csr/ArrowUUpLeft';
import {ArrowRightIcon} from '@phosphor-icons/react/dist/csr/ArrowRight';
import {CopyIcon} from '@phosphor-icons/react/dist/csr/Copy';
import {QuotesIcon} from '@phosphor-icons/react/dist/csr/Quotes';
import {HighlighterIcon} from '@phosphor-icons/react/dist/csr/Highlighter';
import {LockKeyIcon} from '@phosphor-icons/react/dist/csr/LockKey';
import {SparkleIcon} from '@phosphor-icons/react/dist/csr/Sparkle';
import {FileTextIcon} from '@phosphor-icons/react/dist/csr/FileText';
import {FunnelIcon} from '@phosphor-icons/react/dist/csr/Funnel';
import {CrosshairIcon} from '@phosphor-icons/react/dist/csr/Crosshair';
import {KeyboardIcon} from '@phosphor-icons/react/dist/csr/Keyboard';
import {ClockIcon} from '@phosphor-icons/react/dist/csr/Clock';
import {StopIcon} from '@phosphor-icons/react/dist/csr/Stop';
import {SidebarSimpleIcon} from '@phosphor-icons/react/dist/csr/SidebarSimple';
import MarkdownIt from 'markdown-it';
import katex from 'katex';
import 'katex/dist/katex.min.css';
export const AppContext=createContext(null);
export const useApp=()=>useContext(AppContext);
const icons={outline:ListBulletsIcon,sidebar:SidebarSimpleIcon,layers:BooksIcon,"source-index":MagnifyingGlassIcon,book:BookOpenIcon,library:BooksIcon,reader:BookOpenIcon,workflow:GitBranchIcon,chat:ChatCircleTextIcon,notes:NotePencilIcon,map:MapPinIcon,mindmap:TreeStructureIcon,relations:GraphIcon,knowledge:DatabaseIcon,atlas:SquaresFourIcon,cards:FileTextIcon,plugins:PuzzlePieceIcon,models:SlidersHorizontalIcon,settings:SlidersHorizontalIcon,trash:TrashIcon,search:MagnifyingGlassIcon,plus:PlusIcon,minus:MinusIcon,close:XIcon,chevronLeft:CaretLeftIcon,chevronRight:CaretRightIcon,chevronDown:CaretDownIcon,more:DotsThreeIcon,expand:CornersOutIcon,collapse:MinusIcon,grip:DotsSixIcon,check:CheckCircleIcon,warning:WarningCircleIcon,info:InfoIcon,save:FloppyDiskIcon,download:DownloadSimpleIcon,upload:UploadSimpleIcon,link:LinkIcon,eye:EyeIcon,eyeOff:EyeSlashIcon,play:PlayIcon,pause:PauseIcon,refresh:ArrowClockwiseIcon,return:ArrowUUpLeftIcon,arrowRight:ArrowRightIcon,copy:CopyIcon,quote:QuotesIcon,highlight:HighlighterIcon,lock:LockKeyIcon,sparkle:SparkleIcon,file:FileTextIcon,filter:FunnelIcon,target:CrosshairIcon,keyboard:KeyboardIcon,undo:ArrowUUpLeftIcon,clock:ClockIcon,stop:StopIcon,edit:NotePencilIcon};
export function Icon({name,size=20,weight='regular',...props}){const Component=icons[name]||FileTextIcon;return <Component aria-hidden="true" size={size} weight={weight} {...props}/>;}
export function Button({icon,children,variant='default',className='',...props}){return <button type="button" className={'button '+variant+' '+(!children?'icon-button ':'')+className} {...props}>{icon?<Icon name={icon}/>:null}{children}</button>;}
export function Toolbar({children,className='',toolbarRef}){return <div ref={toolbarRef} className={'glass toolbar '+className}>{children}</div>;}
export function Empty({icon='file',title,children,action}){return <div className="empty-state"><Icon name={icon} size={36}/><h2>{title}</h2><div>{children}</div>{action}</div>;}
const md=new MarkdownIt({html:false,linkify:true,breaks:false});
export function Markdown({text='',className=''}){const html=useMemo(()=>{const math=[];let input=text.replace(/\$\$([\s\S]+?)\$\$/g,(_,s)=>{const key='MATHPLACEHOLDER'+math.length+'END';math.push(katex.renderToString(s.trim(),{displayMode:true,throwOnError:false,strict:false}));return '\n\n'+key+'\n\n';});input=input.replace(/\$([^$\n]+)\$/g,(_,s)=>{const key='MATHPLACEHOLDER'+math.length+'END';math.push(katex.renderToString(s,{throwOnError:false,strict:false}));return key;});return md.render(input).replace(/MATHPLACEHOLDER(\d+)END/g,(_,i)=>math[Number(i)]);},[text]);return <div className={'markdown '+className} dangerouslySetInnerHTML={{__html:html}}/>;}
const panelPositions=new Map();
const manuallyPlacedPanels=new Set();
function dockPosition(dock,width,height=340){const w=window.innerWidth,h=window.innerHeight;const left=18,right=w-width-18,bottom=h-height-80;return {x:dock.includes('right')?right:dock.includes('center')?(w-width)/2:left,y:dock.includes('bottom')?bottom:72};}
function clampPosition(p,width,height,bottomReserve=18){return {x:Math.max(12,Math.min(p.x,window.innerWidth-width-12)),y:Math.max(72,Math.min(p.y,window.innerHeight-Math.min(height,Math.max(56,Math.min(window.innerHeight-110,window.innerHeight-72-bottomReserve)))-bottomReserve))};}
export function placeFloatingChrome(size,preferred,bounds,obstacles=[],gap=12){
  if(size.w<=0||size.h<=0||size.w>bounds.w||size.h>bounds.h)return null;
  const clampX=x=>Math.max(bounds.x,Math.min(x,bounds.x+bounds.w-size.w)),clampY=y=>Math.max(bounds.y,Math.min(y,bounds.y+bounds.h-size.h));
  const p={x:clampX(preferred.x),y:clampY(preferred.y)},blocks=obstacles.filter(r=>r&&r.w>0&&r.h>0).map(r=>({x:r.x-gap,y:r.y-gap,w:r.w+gap*2,h:r.h+gap*2}));
  const xs=[p.x,bounds.x,bounds.x+bounds.w-size.w],ys=[p.y,bounds.y,bounds.y+bounds.h-size.h];
  blocks.forEach(r=>{xs.push(clampX(r.x-size.w),clampX(r.x+r.w));ys.push(clampY(r.y-size.h),clampY(r.y+r.h));});
  return xs.flatMap(x=>ys.map(y=>({x,y,...size}))).filter(r=>!blocks.some(b=>r.x<b.x+b.w&&r.x+r.w>b.x&&r.y<b.y+b.h&&r.y+r.h>b.y)).sort((a,b)=>Math.hypot(a.x-p.x,a.y-p.y)-Math.hypot(b.x-p.x,b.y-p.y))[0]||null;
}
export function Panel({id,title,children,width=320,dock='right',initial,actions,footer,className='',snap=false,onVisibilityChange,onFrameChange,onRequestClose,maximumHeight=520,autoCloseBelow=0,autoCollapseBelow=0,avoidRects=[],toolbarRestore=false,collapseToToolbar=false,stationary=false,singleDismiss=false,bottomReserve=18}){
  const ref=useRef(null),drag=useRef(null),wasNarrow=useRef(autoCloseBelow>0&&window.innerWidth<autoCloseBelow),[position,setPosition]=useState(()=>panelPositions.get(id)||initial||dockPosition(dock,Math.min(width,window.innerWidth-32))),[collapsed,setCollapsed]=useState(autoCollapseBelow>0&&window.innerWidth<autoCollapseBelow),[closed,setClosed]=useState(autoCloseBelow>0&&window.innerWidth<autoCloseBelow),[moving,setMoving]=useState(false),[winWidth,setWinWidth]=useState(window.innerWidth);
  const actualWidth=Math.max(240,Math.min(width,winWidth-32));
  useLayoutEffect(()=>{
    if(manuallyPlacedPanels.has(id)||!initial)return;
    const next=clampPosition(initial,actualWidth,Math.min(collapsed?56:maximumHeight,Math.max(56,Math.min(innerHeight-112,innerHeight-72-bottomReserve))),bottomReserve);
    setPosition(old=>old.x===next.x&&old.y===next.y?old:next);
  },[id,initial?.x,initial?.y,actualWidth,collapsed,maximumHeight,bottomReserve]);
  // Avoidance changes only presentation; removing the obstacle restores the
  // reader's chosen position. Never persist a position generated by avoidance.
  function presentation(){
    const wanted=Math.min(collapsed?56:maximumHeight,Math.max(56,Math.min(innerHeight-112,innerHeight-72-bottomReserve))),origin=clampPosition(position,actualWidth,wanted,bottomReserve);
    if(moving)return {...position,h:drag.current?.height||wanted};
    if(!avoidRects.length)return {...origin,h:wanted};
    const obstacles=avoidRects.filter(r=>r&&r.w>0&&r.h>0).map(r=>({x:r.x-8,y:r.y-8,w:r.w+16,h:r.h+16}));
    const overlap=p=>obstacles.reduce((sum,r)=>sum+Math.max(0,Math.min(p.x+actualWidth,r.x+r.w)-Math.max(p.x,r.x))*Math.max(0,Math.min(p.y+p.h,r.y+r.h)-Math.max(p.y,r.y)),0);
    const distance=p=>Math.hypot(p.x-origin.x,p.y-origin.y);
    const fit=(p,h)=>({x:Math.max(24,Math.min(p.x,innerWidth-actualWidth-24)),y:Math.max(bottomReserve>18?72:88,Math.min(p.y,innerHeight-h-bottomReserve)),h});
    const candidates=[origin,{x:24,y:88},{x:innerWidth-actualWidth-24,y:88},{x:24,y:innerHeight-wanted-24},{x:innerWidth-actualWidth-24,y:innerHeight-wanted-24}];
    for(const r of obstacles)candidates.push({x:r.x-actualWidth,y:origin.y},{x:r.x+r.w,y:origin.y},{x:origin.x,y:r.y-wanted},{x:origin.x,y:r.y+r.h});
    const full=candidates.map(p=>fit(p,wanted)).filter(p=>!overlap(p)).sort((a,b)=>distance(a)-distance(b));
    if(full.length)return full[0];
    const bands=[];
    for(const c of candidates){const x=fit(c,56).x,blocks=obstacles.filter(r=>r.x<x+actualWidth&&r.x+r.w>x&&r.y+r.h>88&&r.y<innerHeight-24).sort((a,b)=>a.y-b.y);let cursor=bottomReserve>18?72:88;
      const add=(top,bottom)=>{if(bottom-top>=56){const h=Math.min(wanted,bottom-top);bands.push({x,y:Math.min(Math.max(origin.y,top),bottom-h),h});}};
      for(const r of blocks){if(r.y>cursor)add(cursor,Math.min(r.y,innerHeight-bottomReserve));cursor=Math.max(cursor,r.y+r.h);}add(cursor,innerHeight-bottomReserve);
    }
    return bands.sort((a,b)=>b.h-a.h||distance(a)-distance(b))[0]||candidates.map(p=>fit(p,56)).sort((a,b)=>overlap(a)-overlap(b)||distance(a)-distance(b))[0];
  }
  const displayed=stationary?{x:Math.max(20,(innerWidth-actualWidth)/2),y:Math.max(20,(innerHeight-Math.min(maximumHeight,innerHeight-40))/2),h:Math.min(maximumHeight,innerHeight-40)}:presentation();
  const frameCallback=useRef(onFrameChange);frameCallback.current=onFrameChange;
  const lastFrameToken=useRef('');
  useLayoutEffect(()=>{if(moving)return;const rect=closed?null:ref.current?.getBoundingClientRect();const frame=rect?{x:rect.x,y:rect.y,w:rect.width,h:rect.height}:null,token=JSON.stringify(frame);frameCallback.current?.(frame);if(ref.current)ref.current.dataset.settledFrame=token;if(lastFrameToken.current!==token){lastFrameToken.current=token;window.dispatchEvent(new CustomEvent('prototype-chrome-settled'));}});
  useEffect(()=>()=>window.dispatchEvent(new CustomEvent('prototype-chrome-settled')),[]);
  const wasCompact=useRef(autoCollapseBelow>0&&window.innerWidth<autoCollapseBelow);
  const visibilityRef=useRef(onVisibilityChange);visibilityRef.current=onVisibilityChange;
  useEffect(()=>{visibilityRef.current?.(!closed&&!collapsed);},[closed,collapsed]);
  const fit=useCallback(()=>{const compact=autoCollapseBelow>0&&window.innerWidth<autoCollapseBelow;if(compact&&!wasCompact.current)setCollapsed(true);wasCompact.current=compact;const narrow=autoCloseBelow>0&&window.innerWidth<autoCloseBelow;if(narrow&&!wasNarrow.current)setClosed(true);wasNarrow.current=narrow;setWinWidth(window.innerWidth);setPosition(p=>clampPosition(p,Math.min(width,window.innerWidth-32),ref.current?.offsetHeight||72,bottomReserve));},[width,autoCloseBelow,autoCollapseBelow,bottomReserve]);
  useLayoutEffect(()=>{fit();},[fit,collapsed,closed]);
  useEffect(()=>{window.addEventListener('resize',fit);const open=e=>{if(e.detail?.id===id){setClosed(false);setCollapsed(false);}};const close=e=>{if(e.detail?.id===id)setClosed(true);};window.addEventListener('prototype-panel-open',open);window.addEventListener('prototype-panel-close',close);return()=>{window.removeEventListener('resize',fit);window.removeEventListener('prototype-panel-open',open);window.removeEventListener('prototype-panel-close',close);};},[id,fit]);
  useEffect(()=>{panelPositions.set(id,position);},[id,position]);
  function start(e){if(stationary||e.button!==0||e.target.closest('button,input,select,textarea,a'))return;const p=ref.current.getBoundingClientRect();drag.current={startX:e.clientX,startY:e.clientY,x:p.left,y:p.top,height:p.height};e.currentTarget.setPointerCapture(e.pointerId);setMoving(true);}
  function move(e){if(!drag.current)return;manuallyPlacedPanels.add(id);setPosition(clampPosition({x:drag.current.x+e.clientX-drag.current.startX,y:drag.current.y+e.clientY-drag.current.startY},actualWidth,ref.current?.offsetHeight||72,bottomReserve));}
  function end(){if(!drag.current)return;drag.current=null;setMoving(false);if(snap){const h=ref.current?.offsetHeight||280;setPosition(p=>{const choices=[{x:20,y:96},{x:window.innerWidth-actualWidth-20,y:96},{x:80,y:window.innerHeight-h-24},{x:window.innerWidth-actualWidth-20,y:window.innerHeight-h-24},{x:(window.innerWidth-actualWidth)/2,y:window.innerHeight-h-24}];const nearest=choices.sort((a,b)=>Math.hypot(a.x-p.x,a.y-p.y)-Math.hypot(b.x-p.x,b.y-p.y))[0];return clampPosition(nearest,actualWidth,h,bottomReserve);});}}
  const tray=document.getElementById('panel-tray');
  if(closed){
    if(toolbarRestore||collapseToToolbar||stationary)return null;
    let restoreStyle;
    if(avoidRects.length){
      const preferred={x:dock.includes('left')?24:innerWidth-204,y:dock.includes('left')?106:innerHeight-144};
      const choices=[preferred,...avoidRects.map(r=>({x:preferred.x,y:r.y-52})),{x:innerWidth-204,y:88},{x:24,y:88}].map(p=>({x:Math.max(20,Math.min(p.x,innerWidth-200)),y:Math.max(88,Math.min(p.y,innerHeight-144))}));
      const overlap=p=>avoidRects.reduce((sum,r)=>sum+Math.max(0,Math.min(p.x+180,r.x+r.w+8)-Math.max(p.x,r.x-8))*Math.max(0,Math.min(p.y+44,r.y+r.h+8)-Math.max(p.y,r.y-8)),0);
      const picked=choices.sort((a,b)=>overlap(a)-overlap(b)||Math.hypot(a.x-preferred.x,a.y-preferred.y)-Math.hypot(b.x-preferred.x,b.y-preferred.y))[0];
      restoreStyle={position:'fixed',left:picked.x,top:picked.y,width:180,height:44};
    }
    return tray?createPortal(<Button icon="expand" className="restore-chip" data-panel-id={id} style={restoreStyle} onClick={()=>{setClosed(false);setCollapsed(false);}} aria-label={'恢复'+title}>{title}</Button>,tray):null;
  }
  return <section ref={ref} aria-label={title} data-panel-id={id} className={'glass floating-panel '+(collapsed?'is-collapsed ':'')+(moving?'is-moving ':'')+(stationary?'is-stationary ':'')+className} style={{left:displayed.x,top:displayed.y,width:actualWidth,maxHeight:displayed.h,'--panel-available-height':displayed.h+'px'}}><header className="panel-header" onPointerDown={start} onPointerMove={move} onPointerUp={end} onPointerCancel={end}><h2 title="拖动标题移动面板">{title}</h2><div className="panel-actions">{actions}{!singleDismiss&&!toolbarRestore&&!collapseToToolbar&&<Button icon={collapsed?'expand':'minus'} aria-label={(collapsed?'展开':'收起')+title} title={(collapsed?'展开':'收起')+title} variant="quiet" onClick={()=>{if(collapseToToolbar)setClosed(true);else setCollapsed(c=>!c);}}/>}<Button icon={toolbarRestore||collapseToToolbar?'minus':'close'} aria-label={(toolbarRestore||collapseToToolbar?'收起':'关闭')+title} title={(toolbarRestore||collapseToToolbar?'收起':'关闭')+title} variant="quiet" onClick={()=>{if(onRequestClose?.()!==false)setClosed(true);}}/></div></header><div className="panel-body" hidden={collapsed}>{children}</div>{footer?<footer className="panel-footer" hidden={collapsed}>{footer}</footer>:null}</section>;
}
export function Modal({title,children,onClose,footer}){
  const ref=useRef(null),onCloseRef=useRef(onClose);onCloseRef.current=onClose;
  useEffect(()=>{const before=document.activeElement;const root=ref.current;const focusables=()=>[...root.querySelectorAll('button,input,select,textarea,[tabindex="0"],a[href]')].filter(el=>!el.disabled&&el.offsetParent!==null);focusables()[0]?.focus();const key=e=>{if(e.key==='Escape'){e.stopPropagation();onCloseRef.current();}if(e.key==='Tab'){const list=focusables();if(!list.length)return;const first=list[0],last=list.at(-1);if(e.shiftKey&&document.activeElement===first){e.preventDefault();last.focus();}else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first.focus();}}};root.addEventListener('keydown',key);return()=>{root.removeEventListener('keydown',key);before?.focus?.();};},[]);
  return createPortal(<div className="modal-shade" onPointerDown={e=>{if(e.target===e.currentTarget)onClose();}}><section ref={ref} role="dialog" aria-modal="true" aria-label={title} className="glass modal"><header><h2>{title}</h2><Button icon="close" variant="quiet" aria-label={'关闭'+title} onClick={onClose}/></header><div className="modal-body">{children}</div>{footer?<footer>{footer}</footer>:null}</section></div>,document.body);
}
