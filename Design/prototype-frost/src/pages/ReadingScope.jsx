import React, {useState} from 'react';
import {useApp, Button, Icon} from '../shared.jsx';
import './reader-next.css';

const SCOPES = [
  {id:'selection', title:'所选文字', icon:'highlight', detail:'只解释你确认的选区与少量前后文'},
  {id:'page', title:'当前页', icon:'file', detail:'当前页的可用文字，缺少识别时会说明'},
  {id:'chapter', title:'当前章节', icon:'book', detail:'按章节分段阅读，明确未读部分'},
  {id:'book', title:'整本书', icon:'library', detail:'先检索再取文，不把局部命中称为通读'},
  {id:'notes', title:'我的笔记', icon:'notes', detail:'只使用你勾选的笔记，原书单独标明'},
];

export function readingScopeSnapshot(state, book, requested = state.questionScope || 'page') {
  const page = Math.min(3, Math.max(1, state.source?.page || state.page || 1));
  const selection = state.readerSelection?.bookId === book.id ? state.readerSelection : null;
  const ids = state.readingNoteIds?.[book.id] || [];
  const notes = state.documents.filter(d => d.bookId === book.id && !d.deleted && ids.includes(d.id));
  const title = SCOPES.find(s => s.id === requested)?.title || '当前页';
  const chapter = book.id === 'history' ? '赤壁之战 · 阅读示例' : '第一章 · 线性方程组';
  const valid = requested === 'selection' ? !!selection?.text : requested === 'notes' ? notes.length > 0 : true;
  return Object.freeze({kind:requested, bookId:book.id, bookTitle:book.title, page:requested === 'selection' ? selection?.page || page : page,
    selection:requested === 'selection' ? selection?.text || '' : '',
    noteIds:notes.map(n => n.id), noteTitles:notes.map(n => n.title),
    label:requested === 'selection' ? `${title} · 第 ${selection?.page || page} 页` : requested === 'page' ? `第 ${page} 页` : requested === 'chapter' ? chapter : requested === 'notes' ? `我的笔记 · ${notes.length} 篇` : `${book.title} · 全书`,
    title, valid, frozenAt:Date.now()});
}

export function FrozenScope({snapshot, compact=false}) {
  if (!snapshot) return null;
  return <div className={'scope-frozen '+(compact?'is-compact':'')} data-testid="frozen-scope"><Icon name="lock" size={15}/><span>本次范围已固定 · {snapshot.label}</span>{!compact?<small>之后翻页或切换范围不会改变这次请求</small>:null}</div>;
}

export function ScopePicker({label='提问范围', value, onChange, className=''}) {
  const {state, update, book} = useApp();
  const [open, setOpen] = useState(false);
  const kind = value || state.questionScope || 'page';
  const current = SCOPES.find(s => s.id === kind) || SCOPES[1];
  const selection = state.readerSelection?.bookId === book.id ? state.readerSelection : null;
  const notes = state.documents.filter(d => d.bookId === book.id && !d.deleted);
  const selectedIds = state.readingNoteIds?.[book.id] || [];
  function choose(id) { if (onChange) onChange(id); else update({questionScope:id}); if (id !== 'notes') setOpen(false); }
  function toggleNote(id) { update(prev => { const old = prev.readingNoteIds?.[book.id] || []; return {...prev, readingNoteIds:{...prev.readingNoteIds,[book.id]:old.includes(id)?old.filter(x=>x!==id):[...old,id]}}; }); }
  return <div className={'reading-scope '+className} onKeyDown={e => {if(e.key==='Escape'){e.stopPropagation();setOpen(false);}}}>
    <Button icon={current.icon} variant="quiet" aria-label={label} aria-expanded={open} onClick={()=>setOpen(v=>!v)}>{current.title}<Icon name="chevronDown" size={15}/></Button>
    {open?<><button className="scope-dismiss" tabIndex={-1} aria-label="关闭范围菜单" onClick={()=>setOpen(false)}/><div className="scope-popover glass" role="dialog" aria-label={label+'选项'}>
      <header><strong>{label}</strong><Button icon="close" variant="quiet" aria-label="关闭范围选择" onClick={()=>setOpen(false)}/></header>
      {SCOPES.map(s=><button type="button" key={s.id} className={'scope-option '+(kind===s.id?'is-selected':'')} disabled={s.id==='selection'&&!selection?.text} aria-pressed={kind===s.id} onClick={()=>choose(s.id)}><Icon name={s.icon}/><span><b>{s.title}</b><small>{s.id==='selection'&&!selection?.text?'先在原文中选择文字；PDF 可切到识别文本':s.detail}</small></span>{kind===s.id?<Icon name="check" size={18}/>:null}</button>)}
      {kind==='notes'?<div className="scope-note-list"><p>选定这次允许使用的笔记</p>{notes.map(n=><label key={n.id}><input type="checkbox" checked={selectedIds.includes(n.id)} onChange={()=>toggleNote(n.id)}/><span>{n.title}</span></label>)}{!notes.length?<p>当前书还没有笔记。</p>:null}<Button variant="primary" onClick={()=>setOpen(false)}>完成选择</Button></div>:null}
      <p className="scope-footnote">发送时固定范围。示例交互不读取真实文件或调用 AI。</p>
    </div></>:null}
  </div>;
}
