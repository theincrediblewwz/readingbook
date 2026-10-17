import React,{createContext,useContext,useEffect,useLayoutEffect,useRef,useState,useCallback,useMemo} from 'react';
import {createPortal} from 'react-dom';
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
const icons={sidebar:SidebarSimpleIcon,layers:BooksIcon,"source-index":MagnifyingGlassIcon,book:BookOpenIcon,library:BooksIcon,reader:BookOpenIcon,workflow:GitBranchIcon,chat:ChatCircleTextIcon,notes:NotePencilIcon,map:MapPinIcon,mindmap:TreeStructureIcon,relations:GraphIcon,knowledge:DatabaseIcon,atlas:SquaresFourIcon,cards:FileTextIcon,plugins:PuzzlePieceIcon,models:SlidersHorizontalIcon,settings:SlidersHorizontalIcon,trash:TrashIcon,search:MagnifyingGlassIcon,plus:PlusIcon,minus:MinusIcon,close:XIcon,chevronLeft:CaretLeftIcon,chevronRight:CaretRightIcon,chevronDown:CaretDownIcon,more:DotsThreeIcon,expand:CornersOutIcon,collapse:MinusIcon,grip:DotsSixIcon,check:CheckCircleIcon,warning:WarningCircleIcon,info:InfoIcon,save:FloppyDiskIcon,download:DownloadSimpleIcon,upload:UploadSimpleIcon,link:LinkIcon,eye:EyeIcon,eyeOff:EyeSlashIcon,play:PlayIcon,pause:PauseIcon,refresh:ArrowClockwiseIcon,return:ArrowUUpLeftIcon,arrowRight:ArrowRightIcon,copy:CopyIcon,quote:QuotesIcon,highlight:HighlighterIcon,lock:LockKeyIcon,sparkle:SparkleIcon,file:FileTextIcon,filter:FunnelIcon,target:CrosshairIcon,keyboard:KeyboardIcon,undo:ArrowUUpLeftIcon,clock:ClockIcon,stop:StopIcon,edit:NotePencilIcon};
export function Icon({name,size=20,weight='regular',...props}){const Component=icons[name]||FileTextIcon;return <Component aria-hidden="true" size={size} weight={weight} {...props}/>;}
export function Button({icon,children,variant='default',className='',...props}){return <button type="button" className={'button '+variant+' '+(!children?'icon-button ':'')+className} {...props}>{icon?<Icon name={icon}/>:null}{children}</button>;}
export function Toolbar({children,className=''}){return <div className={'glass toolbar '+className}>{children}</div>;}
export function Empty({icon='file',title,children,action}){return <div className="empty-state"><Icon name={icon} size={36}/><h2>{title}</h2><div>{children}</div>{action}</div>;}
const md=new MarkdownIt({html:false,linkify:true,breaks:false});
export function Markdown({text='',className=''}){const html=useMemo(()=>{const math=[];let input=text.replace(/\$\$([\s\S]+?)\$\$/g,(_,s)=>{const key='MATHPLACEHOLDER'+math.length+'END';math.push(katex.renderToString(s.trim(),{displayMode:true,throwOnError:false,strict:false}));return '\n\n'+key+'\n\n';});input=input.replace(/\$([^$\n]+)\$/g,(_,s)=>{const key='MATHPLACEHOLDER'+math.length+'END';math.push(katex.renderToString(s,{throwOnError:false,strict:false}));return key;});return md.render(input).replace(/MATHPLACEHOLDER(\d+)END/g,(_,i)=>math[Number(i)]);},[text]);return <div className={'markdown '+className} dangerouslySetInnerHTML={{__html:html}}/>;}
const panelPositions=new Map();
function dockPosition(dock,width,height=340){const w=window.innerWidth-64,h=window.innerHeight;const left=76,right=w-width-26,bottom=h-height-80;return {x:dock.includes('right')?right:dock.includes('center')?(w-width)/2:left,y:dock.includes('bottom')?bottom:106};}
function clampPosition(p,width,height){return {x:Math.max(12,Math.min(p.x,window.innerWidth-64-width-12)),y:Math.max(84,Math.min(p.y,window.innerHeight-Math.min(height,window.innerHeight-110)-18))};}
export function Panel({id,title,children,width=320,dock='right',initial,actions,footer,className='',snap=false,onVisibilityChange,autoCloseBelow=0}){
  const ref=useRef(null),drag=useRef(null),wasNarrow=useRef(autoCloseBelow>0&&window.innerWidth<autoCloseBelow),[position,setPosition]=useState(()=>panelPositions.get(id)||initial||dockPosition(dock,Math.min(width,window.innerWidth-96))),[collapsed,setCollapsed]=useState(false),[closed,setClosed]=useState(autoCloseBelow>0&&window.innerWidth<autoCloseBelow),[moving,setMoving]=useState(false),[winWidth,setWinWidth]=useState(window.innerWidth);
  const actualWidth=Math.max(240,Math.min(width,winWidth-96));
  const visibilityRef=useRef(onVisibilityChange);visibilityRef.current=onVisibilityChange;
  useEffect(()=>{visibilityRef.current?.(!closed&&!collapsed);},[closed,collapsed]);
  const fit=useCallback(()=>{const narrow=autoCloseBelow>0&&window.innerWidth<autoCloseBelow;if(narrow&&!wasNarrow.current)setClosed(true);wasNarrow.current=narrow;setWinWidth(window.innerWidth);setPosition(p=>clampPosition(p,Math.min(width,window.innerWidth-96),ref.current?.offsetHeight||72));},[width,autoCloseBelow]);
  useLayoutEffect(()=>{fit();},[fit,collapsed,closed]);
  useEffect(()=>{window.addEventListener('resize',fit);const open=e=>{if(e.detail?.id===id){setClosed(false);setCollapsed(false);}};const close=e=>{if(e.detail?.id===id)setClosed(true);};window.addEventListener('prototype-panel-open',open);window.addEventListener('prototype-panel-close',close);return()=>{window.removeEventListener('resize',fit);window.removeEventListener('prototype-panel-open',open);window.removeEventListener('prototype-panel-close',close);};},[id,fit]);
  useEffect(()=>{panelPositions.set(id,position);},[id,position]);
  function start(e){if(e.button!==0||e.target.closest('button,input,select,textarea,a'))return;const p=ref.current.getBoundingClientRect();drag.current={startX:e.clientX,startY:e.clientY,x:p.left,y:p.top};e.currentTarget.setPointerCapture(e.pointerId);setMoving(true);}
  function move(e){if(!drag.current)return;setPosition(clampPosition({x:drag.current.x+e.clientX-drag.current.startX,y:drag.current.y+e.clientY-drag.current.startY},actualWidth,ref.current?.offsetHeight||72));}
  function end(){if(!drag.current)return;drag.current=null;setMoving(false);if(snap){const h=ref.current?.offsetHeight||280;setPosition(p=>{const choices=[{x:20,y:96},{x:window.innerWidth-64-actualWidth-20,y:96},{x:20,y:window.innerHeight-h-24},{x:window.innerWidth-64-actualWidth-20,y:window.innerHeight-h-24},{x:(window.innerWidth-64-actualWidth)/2,y:window.innerHeight-h-24}];const nearest=choices.sort((a,b)=>Math.hypot(a.x-p.x,a.y-p.y)-Math.hypot(b.x-p.x,b.y-p.y))[0];return clampPosition(nearest,actualWidth,h);});}}
  const tray=document.getElementById('panel-tray');
  if(closed)return tray?createPortal(<Button icon="expand" className="restore-chip" onClick={()=>{setClosed(false);setCollapsed(false);}} aria-label={'恢复'+title}>{title}</Button>,tray):null;
  return <section ref={ref} aria-label={title} data-panel-id={id} className={'glass floating-panel '+(collapsed?'is-collapsed ':'')+(moving?'is-moving ':'')+className} style={{left:position.x,top:position.y,width:actualWidth,maxHeight:Math.max(72,window.innerHeight-position.y-18)}}><header className="panel-header" onPointerDown={start} onPointerMove={move} onPointerUp={end} onPointerCancel={end}><Icon name="grip" size={18}/><h2>{title}</h2><div className="panel-actions">{actions}<Button icon={collapsed?'expand':'minus'} aria-label={(collapsed?'展开':'收起')+title} title={(collapsed?'展开':'收起')+title} variant="quiet" onClick={()=>setCollapsed(c=>!c)}/><Button icon="close" aria-label={'关闭'+title} title={'关闭'+title} variant="quiet" onClick={()=>setClosed(true)}/></div></header>{!collapsed?<><div className="panel-body">{children}</div>{footer?<footer className="panel-footer">{footer}</footer>:null}</>:null}</section>;
}
export function Modal({title,children,onClose,footer}){
  const ref=useRef(null),onCloseRef=useRef(onClose);onCloseRef.current=onClose;
  useEffect(()=>{const before=document.activeElement;const root=ref.current;const focusables=()=>[...root.querySelectorAll('button,input,select,textarea,[tabindex="0"],a[href]')].filter(el=>!el.disabled&&el.offsetParent!==null);focusables()[0]?.focus();const key=e=>{if(e.key==='Escape'){e.stopPropagation();onCloseRef.current();}if(e.key==='Tab'){const list=focusables();if(!list.length)return;const first=list[0],last=list.at(-1);if(e.shiftKey&&document.activeElement===first){e.preventDefault();last.focus();}else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first.focus();}}};root.addEventListener('keydown',key);return()=>{root.removeEventListener('keydown',key);before?.focus?.();};},[]);
  return createPortal(<div className="modal-shade" onPointerDown={e=>{if(e.target===e.currentTarget)onClose();}}><section ref={ref} role="dialog" aria-modal="true" aria-label={title} className="glass modal"><header><h2>{title}</h2><Button icon="close" variant="quiet" aria-label={'关闭'+title} onClick={onClose}/></header><div className="modal-body">{children}</div>{footer?<footer>{footer}</footer>:null}</section></div>,document.body);
}
