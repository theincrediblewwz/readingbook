import React,{useEffect,useRef,useState} from 'react';
import {useApp,Button,Icon} from '../shared.jsx';
import {ScopePicker} from './ReadingScope.jsx';

const docks=['top-left','top-right','bottom-left','bottom-right','bottom-center'];
const clamp=(value,min,max)=>Math.max(min,Math.min(value,Math.max(min,max)));
export default function FloatingQuestion({expanded,onExpand,question,setQuestion,onSend,asking,onFrame}){
  const {state,update,book,navigate}=useApp();
  const saved=state.questionLayouts?.[book.id];
  const [dock,setDock]=useState(saved?.dock||'bottom-right'),[size,setSize]=useState(saved?.size||{w:440,h:184});
  const [viewport,setViewport]=useState({w:innerWidth,h:innerHeight}),[live,setLive]=useState(null),gesture=useRef(null);
  const bounds={x:20,y:88,w:Math.max(58,viewport.w-40),h:Math.max(58,viewport.h-184)};
  const fitted=desired=>({w:Math.min(bounds.w,clamp(desired.w,340,760)),h:Math.min(bounds.h,clamp(desired.h,156,480))});
  const actual=expanded?fitted(size):{w:58,h:58};
  function at(place,dimensions=actual){return {x:place.endsWith('right')?bounds.x+bounds.w-dimensions.w:place.endsWith('center')?bounds.x+(bounds.w-dimensions.w)/2:bounds.x,y:place.startsWith('top')?bounds.y:bounds.y+bounds.h-dimensions.h,...dimensions};}
  const frame=live||at(dock);
  const nearest=point=>docks.reduce((best,place)=>{const p=at(place);return Math.hypot(p.x-point.x,p.y-point.y)<Math.hypot(at(best).x-point.x,at(best).y-point.y)?place:best;},dock);
  function persist(nextDock,nextSize=size){update(prev=>({...prev,questionLayouts:{...prev.questionLayouts,[book.id]:{dock:nextDock,size:nextSize}}}));}
  useEffect(()=>{const resize=()=>{gesture.current=null;setLive(null);setViewport({w:innerWidth,h:innerHeight});};addEventListener('resize',resize);return()=>removeEventListener('resize',resize);},[]);
  useEffect(()=>{setDock(saved?.dock||'bottom-right');setSize(saved?.size||{w:440,h:184});gesture.current=null;setLive(null);},[book.id]);
  useEffect(()=>{if(!gesture.current)onFrame?.(frame);},[dock,size.w,size.h,viewport.w,viewport.h,expanded]);
  function begin(e,kind){if(e.button!==0||e.target.closest('[data-no-drag]'))return;e.preventDefault();e.stopPropagation();gesture.current={kind,x:e.clientX,y:e.clientY,frame:{...frame},size:{...actual},dock};e.currentTarget.setPointerCapture(e.pointerId);}
  function move(e){const g=gesture.current;if(!g)return;const dx=e.clientX-g.x,dy=e.clientY-g.y;if(g.kind==='drag'){setLive({...g.frame,x:clamp(g.frame.x+dx,bounds.x,bounds.x+bounds.w-g.frame.w),y:clamp(g.frame.y+dy,bounds.y,bounds.y+bounds.h-g.frame.h)});}else{const desired=fitted({w:g.size.w+(g.dock.endsWith('right')?-dx:g.dock.endsWith('center')?2*dx:dx),h:g.size.h+(g.dock.startsWith('bottom')?-dy:dy)});setLive(at(g.dock,desired));}}
  function end(){const g=gesture.current;if(!g)return;gesture.current=null;const final=live||g.frame,nextDock=g.kind==='drag'?nearest(final):g.dock,nextSize=g.kind==='resize'?{w:final.w,h:final.h}:size;setDock(nextDock);setSize(nextSize);setLive(null);persist(nextDock,nextSize);onFrame?.(at(nextDock,expanded?fitted(nextSize):{w:58,h:58}));}
  const resizeStyle={left:dock.endsWith('right')?-7:undefined,right:dock.endsWith('right')?undefined:-7,top:dock.startsWith('bottom')?-7:undefined,bottom:dock.startsWith('bottom')?undefined:-7};
  return <div data-dock={dock} className={'question-floater '+(expanded?'expanded':'collapsed')+(live?' moving':'')} style={{left:frame.x,top:frame.y,width:frame.w,height:frame.h}}>
    {expanded?<form className="question-card glass" onSubmit={e=>{e.preventDefault();onSend();}}>
      <header><button type="button" className="question-drag" aria-label="移动 AI 提问" title="拖动到四角或下方中央" onPointerDown={e=>begin(e,'drag')} onPointerMove={move} onPointerUp={end} onPointerCancel={()=>{gesture.current=null;setLive(null);}}><Icon name="grip" size={18}/><span>问 AI</span></button><Button icon="minus" variant="quiet" aria-label="收起 AI 提问" title="收起并保留草稿" onClick={()=>onExpand(false)}/></header>
      <div className="question-scope"><ScopePicker label="提问范围"/><Button icon="chat" variant="quiet" title="打开完整对话" aria-label="打开完整对话" onClick={()=>navigate('chat')}/></div>
      <div className="question-writing"><textarea aria-label="继续提问" placeholder="问一个问题…" value={question} onChange={e=>setQuestion(e.target.value)} onKeyDown={e=>{if(e.key==='Enter'&&!e.shiftKey&&!e.nativeEvent.isComposing){e.preventDefault();onSend();}}}/><Button type="submit" icon="arrowRight" variant="primary" aria-label="发送伴读问题" disabled={asking||!question.trim()}/></div>
      <button type="button" className="question-resize" style={resizeStyle} aria-label="调整提问框大小" title="拖动调整大小；方向键微调" onPointerDown={e=>begin(e,'resize')} onPointerMove={move} onPointerUp={end} onPointerCancel={()=>{gesture.current=null;setLive(null);}} onKeyDown={e=>{if(!['ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].includes(e.key))return;e.preventDefault();const next=fitted({w:size.w+(e.key==='ArrowRight'?24:e.key==='ArrowLeft'?-24:0),h:size.h+(e.key==='ArrowDown'?24:e.key==='ArrowUp'?-24:0)});setSize(next);persist(dock,next);}}><Icon name="expand" size={16}/></button>
    </form>:<Button className="question-orb glass" icon="chat" aria-label="展开 AI 提问" title={question?'继续未发送的问题':'问 AI'} onClick={()=>onExpand(true)}/>}
  </div>;
}
