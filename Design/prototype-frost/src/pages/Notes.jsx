import React, { useEffect, useRef, useState } from 'react';
import { useApp, Icon, Button, Panel, Toolbar, Modal, Markdown, Empty } from '../shared.jsx';
import { books } from '../data.js';
import { SPATIAL_EVENTS } from './Spatial.jsx';
import {ScopePicker, FrozenScope, readingScopeSnapshot} from './ReadingScope.jsx';
import './notes.css';

const uid = (prefix = 'note') => `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`;
const sourceFor = (book) => book.kind === 'history' || book.id === 'history'
  ? SPATIAL_EVENTS.find(event => event.id === 'h-redcliff').source
  : { page: 1, paragraph: 2, chapter: '线性方程组', text: '行变换不改变方程组的解集。先消去第一列，再寻找主元。' };
const stamp = (value) => value ? new Date(value).toLocaleDateString('zh-CN', { month: 'numeric', day: 'numeric' }) : '示例笔记';
const makeNode = (docId, bookId, count = 0) => ({ id: `n-${docId}`, bookId, docId, x: 200 + count * 34, y: 180 + count * 24 });
const excerpt = (text = '', count = 90) => text.replace(/[#*>`$\[\]]/g, '').slice(0, count);
const withoutTitle = (markdown = '') => markdown.replace(/^\s*# [^\n]+\n+/, '');
const previewText = (markdown = '', source) => {
  const body = withoutTitle(markdown);
  if (!source?.text) return body;
  const normalize = value => value.replace(/[\s“”"「」『』]/g, '');
  return body.replace(/(?:^|\n)(>[^\n]*(?:\n>[^\n]*)*)\s*$/, (match, quote) => quote.includes('原文') && normalize(quote).includes(normalize(source.text)) ? '' : match);
};

function SourceQuote({ source, onReturn }) {
  if (!source) return null;
  return <aside className="nt-source"><span>原文 · 第 {source.page || 1} 页{source.chapter ? ` · ${source.chapter}` : ''}</span><p>“{source.text}”</p><Button icon="return" variant="quiet" onClick={onReturn}>返回原句</Button></aside>;
}

export function NotesPage() {
  const { state, update, navigate, notify, confirm, registerGuard, book } = useApp();
  const allDocs = state.documents || [];
  const available = allDocs.filter(d => d.bookId === state.currentBookId && !d.deleted);
  const selected = available.find(d => d.id === state.selectedDocId) || available[0];
  const [draft, setDraft] = useState(() => selected ? { ...selected, isNew: false } : null);
  const [mode, setMode] = useState('preview');
  const [listVisible, setListVisible] = useState(true);
  const [query, setQuery] = useState('');
  const [more, setMore] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  const [guardOpen, setGuardOpen] = useState(false);
  const guardResolve = useRef(null);
  const draftRef = useRef(draft);
  const savingRef = useRef(false);
  const dirty = !!draft && (draft.isNew || draft.title !== (allDocs.find(d => d.id === draft.id)?.title || '') || draft.markdown !== (allDocs.find(d => d.id === draft.id)?.markdown || ''));
  const dirtyRef = useRef(dirty);
  draftRef.current = draft; dirtyRef.current = dirty;

  useEffect(() => {
    if (!dirtyRef.current) { setDraft(selected ? { ...selected, isNew: false } : null); setError(''); }
  }, [state.selectedDocId, state.currentBookId, selected?.id, selected?.title, selected?.markdown]);
  useEffect(() => {
    if (state.noteDraftRequest) {
      const request=typeof state.noteDraftRequest==='object'?state.noteDraftRequest:{};
      setDraft({ id: uid(), bookId: state.currentBookId, title: request.title||'未命名笔记', markdown: request.markdown||'', source: request.source||null, isNew: true });
      setMode('edit'); setError(''); update({ noteDraftRequest: null });
    }
  }, [state.noteDraftRequest]);

  const saveDraft = async () => {
    const next = draftRef.current;
    if (!next || savingRef.current) return false;
    if (!next.title.trim()) { setError('请为笔记填写标题。正文仍保留在草稿中。'); setMode('edit'); return false; }
    if (!next.markdown.trim()) { setError('正文还是空的，写下一点理解后再保存。'); setMode('edit'); return false; }
    savingRef.current = true; setSaving(true); setError('');
    await new Promise(resolve => setTimeout(resolve, 380));
    const saved = { ...next, title: next.title.trim(), deleted: false, updatedAt: new Date().toISOString() };
    delete saved.isNew;
    update(prev => ({ ...prev, selectedDocId: saved.id, documents: prev.documents.some(d => d.id === saved.id) ? prev.documents.map(d => d.id === saved.id ? saved : d) : [...prev.documents, saved] }));
    setDraft(current => current?.id === next.id && current.title === next.title && current.markdown === next.markdown ? { ...saved, isNew: false } : current);
    savingRef.current = false; setSaving(false); notify('笔记已保存到交互稿示例数据；可下载 Markdown。');
    return true;
  };
  const saveRef = useRef(saveDraft); saveRef.current = saveDraft;
  const askGuard = () => {
    if (savingRef.current) { notify('正在保存，请稍候。'); return Promise.resolve(false); }
    if (!dirtyRef.current) return Promise.resolve(true);
    return new Promise(resolve => { guardResolve.current = resolve; setGuardOpen(true); });
  };
  useEffect(() => registerGuard ? registerGuard(askGuard) : undefined, [registerGuard]);
  useEffect(() => { const f = () => saveRef.current(); window.addEventListener('prototype-primary', f); return () => window.removeEventListener('prototype-primary', f); }, []);
  useEffect(() => { const f = (e) => { if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 's') { e.preventDefault(); saveRef.current(); } }; window.addEventListener('keydown', f); return () => window.removeEventListener('keydown', f); }, []);
  useEffect(() => () => { guardResolve.current?.(false); }, []);
  useEffect(() => { const f = (e) => { if (e.key === 'Escape') setMore(false); }; window.addEventListener('keydown', f); return () => window.removeEventListener('keydown', f); }, []);

  const resolveGuard = (result) => { const resolve = guardResolve.current; guardResolve.current = null; setGuardOpen(false); resolve?.(result); };
  const discard = () => { setDraft(selected ? { ...selected, isNew: false } : null); setError(''); dirtyRef.current = false; };
  const switchDoc = async (doc) => { if (!(await askGuard())) return; setDraft({ ...doc, isNew: false }); update({ selectedDocId: doc.id }); setError(''); };
  const create = async () => {
    if (!(await askGuard())) return;
    setDraft({ id: uid(), bookId: state.currentBookId, title: '未命名笔记', markdown: '', source: null, isNew: true }); setMode('edit'); setError('');
  };
  const addToMap = () => {
    if (!draft || dirty) { notify('先保存这份笔记，再加入导图。'); return; }
    update(prev => ({ ...prev, graphNodes: prev.graphNodes.some(n => n.docId === draft.id) ? prev.graphNodes : [...prev.graphNodes, makeNode(draft.id, draft.bookId, prev.graphNodes.length)] }));
    notify('已加入思维导图，节点引用同一份 Markdown。'); setMore(false);
  };
  const trash = async () => {
    if (!draft || dirty || saving) { notify('先保存或放弃草稿，再移入回收站。'); return; }
    if (!(await confirm({ title: '将这份笔记移入回收站？', body: `“${draft.title}”的导图节点会暂时隐藏；恢复笔记后会重新出现。原书不会改变。`, confirmLabel: '移入回收站', danger: true }))) return;
    const remaining = available.find(d => d.id !== draft.id);
    update(prev => ({ ...prev, documents: prev.documents.map(d => d.id === draft.id ? { ...d, deleted: true } : d), selectedDocId: remaining?.id || null }));
    setDraft(remaining ? { ...remaining, isNew: false } : null); setMore(false); notify('笔记已移入回收站，可恢复。');
  };
  const download = () => {
    if (!draft) return;
    const url = URL.createObjectURL(new Blob([`# ${draft.title}\n\n${withoutTitle(draft.markdown)}`], { type: 'text/markdown;charset=utf-8' }));
    const link = document.createElement('a'); link.href = url; link.download = `${draft.title || '笔记'}.md`; link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000); setMore(false); notify('已下载 Markdown 文件。');
  };
  const rows = available.filter(d => `${d.title} ${d.markdown}`.toLowerCase().includes(query.toLowerCase()));
  return <section className={`nt-page nt-notes-page ${listVisible ? '' : 'nt-list-hidden'}`} aria-label="我的笔记">
    <Panel toolbarRestore bottomReserve={88} id="notes-list" title="我的笔记" dock="left" width={340} className="nt-list-panel" autoCloseBelow={1050} onVisibilityChange={setListVisible} footer={<Button icon="plus" onClick={create}>新建笔记</Button>}>
      <label className="nt-search"><Icon name="search" size={18}/><input aria-label="搜索笔记" placeholder="搜索笔记…" value={query} onChange={e => setQuery(e.target.value)}/>{query && <button aria-label="清空笔记搜索" onClick={() => setQuery('')}><Icon name="close" size={16}/></button>}</label>
      <div className="nt-note-list">{rows.map(doc => <button key={doc.id} className={`nt-note-row ${draft?.id === doc.id ? 'selected' : ''}`} onClick={() => switchDoc(doc)}><Icon name="file" size={24}/><span><strong>{doc.title}</strong><small>{stamp(doc.updatedAt)}{doc.source ? ` · 第 ${doc.source.page} 页` : ' · 用户笔记'}</small></span>{draft?.id === doc.id && <Icon name="check" size={17}/>}</button>)}{!rows.length && <p className="nt-empty-small">{query ? '没有找到这份笔记' : '还没有保存的笔记'}</p>}</div>
    </Panel>
    <main className="nt-document-wrap">
      {!draft ? <div className="nt-document nt-empty-paper"><Empty icon="notes" title="写下你自己的理解" action={<Button icon="plus" variant="primary" onClick={create}>新建笔记</Button>}>笔记、原书和 AI 分析分开保存。</Empty></div> : <article className="nt-document">
        <div className="nt-document-meta"><span>用户笔记{draft.source ? ` · 第 ${draft.source.page} 页` : ''}</span><span className={dirty ? 'nt-unsaved' : ''}>{saving ? '正在保存…' : dirty ? '有未保存修改' : '已保存'}</span></div>
        {mode === 'edit' ? <><input className="nt-title-input" aria-label="笔记标题" value={draft.title} disabled={saving} onChange={e => { setDraft(d => ({ ...d, title: e.target.value })); setError(''); }}/><textarea className="nt-markdown-input" aria-label="Markdown 正文" spellCheck="false" placeholder={'写下你的理解…\n\n支持 Markdown 和 $LaTeX$ 公式。'} value={draft.markdown} onChange={e => { setDraft(d => ({ ...d, markdown: e.target.value })); setError(''); }}/></> : <><h1>{draft.title}</h1><Markdown text={previewText(draft.markdown, draft.source)}/>{!draft.markdown.trim() && <p className="nt-empty-small">正文还是空的，切换到编辑开始写。</p>}</>}
        {error && <p className="nt-error" role="alert"><Icon name="warning" size={18}/>{error}</p>}
        <SourceQuote source={draft.source} onReturn={() => navigate('reader', { source: { ...draft.source, paragraph: draft.source.paragraph || 1 } })}/>
      </article>}
    </main>
    <Toolbar className="nt-editor-toolbar"><Button icon="save" aria-label="保存笔记" title="保存笔记 · Ctrl/⌘ S" disabled={!draft||saving} onClick={saveDraft}/><span className="tool-divider"/><div className="nt-segment" aria-label="笔记显示方式"><button className={mode === 'edit' ? 'active' : ''} onClick={() => setMode('edit')}>编辑</button><button className={mode === 'preview' ? 'active' : ''} onClick={() => setMode('preview')}>预览</button></div><span className="nt-toolbar-divider"/><Button icon="outline" aria-label="笔记列表" title="笔记列表" className={listVisible?'is-selected':''} onClick={()=>window.dispatchEvent(new CustomEvent(listVisible?'prototype-panel-close':'prototype-panel-open',{detail:{id:'notes-list'}}))}/><div className="nt-menu-anchor"><Button icon="more" aria-label="笔记更多操作" aria-expanded={more} onClick={() => setMore(v => !v)}/>{more && <div className="nt-menu" role="menu"><button onClick={addToMap} disabled={!draft || dirty}><Icon name="mindmap"/>加入导图</button><button onClick={download} disabled={!draft}><Icon name="download"/>下载 Markdown</button><button onClick={async () => { setMore(false); if (await confirm({ title: '放弃未保存的修改？', body: '已保存的笔记会保留。当前草稿修改将被放弃。', confirmLabel: '放弃修改', danger: true })) discard(); }} disabled={!dirty}><Icon name="undo"/>放弃修改</button><button className="nt-danger" onClick={trash} disabled={!draft || dirty || saving}><Icon name="trash"/>移入回收站</button><button onClick={() => navigate('trash')}><Icon name="undo"/>查看回收站</button></div>}</div></Toolbar>
    {guardOpen && <Modal title="保留这份草稿？" onClose={() => resolveGuard(false)} footer={<><Button onClick={() => resolveGuard(false)}>继续编辑</Button><Button variant="danger" onClick={() => { discard(); resolveGuard(true); }}>放弃修改</Button><Button icon="save" variant="primary" disabled={saving} onClick={async () => { if (await saveRef.current()) resolveGuard(true); }}>保存并继续</Button></>}><p>这份笔记还有未保存修改。先保存或放弃，再离开当前文档。</p>{error && <p className="nt-error" role="alert">{error}</p>}</Modal>}
  </section>;
}

function SaveAnswerModal({ request, onClose, onSaved }) {
  const { state, update, notify, book } = useApp();
  const [title, setTitle] = useState(request.title || '阅读中的一点理解');
  const [markdown, setMarkdown] = useState(request.markdown || '');
  const [selection, setSelection] = useState('');
  const [sourceMode, setSourceMode] = useState(request.mode === 'source');
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  const sourceEl = useRef(null);
  const content = sourceMode ? selection : markdown;
  const duplicate = state.documents.find(d => d.bookId === state.currentBookId && d.markdown === content.trim());
  const save = async () => {
    if (!title.trim() || !content.trim()) { setError(sourceMode ? '请填写标题，并在 Markdown 源文中选取一段内容。' : '请填写标题并保留需要保存的内容。'); return; }
    if (duplicate?.deleted) {
      update(prev => ({ ...prev, documents: prev.documents.map(d => d.id === duplicate.id ? { ...d, deleted: false } : d) })); notify('已恢复原来的摘记，保留文档与节点身份。'); onSaved?.(duplicate.id); onClose(); return;
    }
    if (duplicate) { notify('相同内容已经保存，未创建副本。'); onSaved?.(duplicate.id); onClose(); return; }
    setSaving(true); await new Promise(r => setTimeout(r, 350));
    const doc = { id: uid('answer'), bookId: state.currentBookId, title: title.trim(), markdown: content.trim(), deleted: false, updatedAt: new Date().toISOString(), source: sourceFor(book) };
    update(prev => ({ ...prev, documents: [...prev.documents, doc], graphNodes: [...prev.graphNodes, makeNode(doc.id, doc.bookId, prev.graphNodes.length)] }));
    notify('已主动保存为示例 Markdown 笔记，并加入导图。'); onSaved?.(doc.id); onClose();
  };
  return <Modal title={request.mode === 'merge' ? '合并保存回答' : '保存回答摘记'} onClose={() => { if (!saving) onClose(); }} footer={<><Button disabled={saving} onClick={onClose}>取消</Button><Button variant="primary" icon={duplicate?.deleted ? 'undo' : 'save'} disabled={saving || !title.trim() || !content.trim()} onClick={save}>{saving ? '保存中…' : duplicate?.deleted ? '恢复原摘记' : duplicate ? '打开已保存笔记' : '保存为 Markdown'}</Button></>}>
    <div className="nt-save-form"><label>笔记标题<input value={title} aria-label="摘记标题" onChange={e => setTitle(e.target.value)} disabled={saving}/></label><p className="nt-muted">只有点击保存，回答才会成为你的笔记。这里使用示例数据。</p>
      <div className="nt-segment"><button className={!sourceMode ? 'active' : ''} disabled={saving} onClick={() => setSourceMode(false)}>整理内容</button><button className={sourceMode ? 'active' : ''} disabled={saving} onClick={() => setSourceMode(true)}>选择 Markdown 源文</button></div>
      {sourceMode ? <><p className="nt-muted">在下面拖选源文；公式的 LaTeX 也会被完整保留。</p><textarea ref={sourceEl} className="nt-source-select" aria-label="选择 Markdown 源文片段" readOnly value={markdown} onSelect={e => { const el = e.target; setSelection(markdown.slice(el.selectionStart, el.selectionEnd)); }}/><span className="nt-muted">已选 {selection.length} 个字符</span></> : <textarea className="nt-save-text" aria-label="待保存 Markdown" value={markdown} disabled={saving} onChange={e => setMarkdown(e.target.value)}/>}
      <div className="nt-save-preview"><span className="nt-eyebrow">保存预览</span>{content ? <Markdown text={content}/> : <p className="nt-muted">选取内容后，这里会显示预览。</p>}</div>{duplicate?.deleted && <p className="nt-status">相同摘记已在回收站中，可恢复原件。</p>}{error && <p className="nt-error" role="alert">{error}</p>}
    </div>
  </Modal>;
}

export function ChatPage() {
  const { state, update, navigate, notify, book } = useApp();
  const [question, setQuestion] = useState('');
  const [busy, setBusy] = useState(false);
  const [selected, setSelected] = useState([]);
  const [multi, setMulti] = useState(false);
  const [saveRequest, setSaveRequest] = useState(null);
  const [menuId, setMenuId] = useState(null);
  const [semanticSelection, setSemanticSelection] = useState(null);
  const messages = (state.messages || []).filter(m => m.bookId === state.currentBookId);
  useEffect(() => { setSelected([]); setMulti(false); setSaveRequest(null); setSemanticSelection(null); }, [state.currentBookId]);
  useEffect(() => { const f = (e) => { if (e.key === 'Escape') { setMenuId(null); setSemanticSelection(null); } }; window.addEventListener('keydown', f); return () => window.removeEventListener('keydown', f); }, []);
  const requestSave = (text, mode = 'whole') => { setSaveRequest({ markdown: text, mode, title: book.id === 'history' ? '赤壁战局中的因果与选择' : '为什么行变换不改变解集' }); setMenuId(null); };
  const send = async () => {
    if (!question.trim() || busy) return;
    const q = question.trim(), snapshot = readingScopeSnapshot(state, book);
    if (!snapshot.valid) { notify(snapshot.kind === 'notes' ? '请先勾选允许使用的笔记。' : '请先在原文中选择文字。'); return; }
    const requestSource = snapshot.kind === 'selection' ? {page: snapshot.page, text: snapshot.selection} : {...sourceFor(book), page:snapshot.page};
    setQuestion(''); setBusy(true);
    update(prev => ({ ...prev, messages: [...prev.messages, { id: uid('q'), role: 'user', text: q, bookId: snapshot.bookId, scope: snapshot, source: requestSource }] }));
    await new Promise(r => setTimeout(r, 650));
    const answer = book.id === 'history'
      ? `### 从原文出发\n\n火攻奏效并不只是“有风”。连船、军队适应程度与部署共同构成了条件。\n\n1. **观察条件**：船舰首尾相接。\n2. **提出方案**：黄盖建议以火攻破局。\n3. **追问证据**：哪些细节是原文明说，哪些是我们的推断？\n\n> 这是交互稿的示例回答，没有调用 AI。`
      : `### 保持解集的关键是可逆\n\n例如，将第二行替换为\n\n$$R_2 \\leftarrow R_2 - 2R_1$$\n\n这一步可以用 $R_2 \\leftarrow R_2 + 2R_1$ 逆转，所以没有引入或丢掉约束。\n\n**再想一步**：把某一行乘以零，为什么不属于合法的初等行变换？\n\n> 这是交互稿的示例回答，没有调用 AI。`;
    update(prev => ({ ...prev, messages: [...prev.messages, { id: uid('a'), role: 'assistant', text: (snapshot.kind==='notes'?'### 从选定笔记出发\n\n本次只演示整理你勾选的笔记，用户理解与原书事实分别标注。可以继续选择范围，或回读完整笔记。\n\n> 本地交互示例，没有调用 AI。':answer), bookId: snapshot.bookId, scope: snapshot, source: requestSource }] })); setBusy(false);
  };
  const captureSelection = (id) => { const text = window.getSelection()?.toString().trim(); if (text) setSemanticSelection({ id, text }); };
  const merged = messages.filter(m => m.role === 'assistant' && selected.includes(m.id)).map((m, i) => `## 回答 ${i + 1}\n\n${m.text}`).join('\n\n---\n\n');
  return <section className="nt-page nt-chat-page" aria-label="与书对话">
    <div className="nt-chat-context"><Icon name="quote" size={19}/><ScopePicker label="对话范围"/><span>发送时固定范围</span><Button icon="return" variant="quiet" onClick={() => navigate('reader')}>回到原文</Button></div>
    <main className="nt-conversation">{!messages.length && <Empty icon="chat" title="从一个问题开始">可以问“这一段为什么成立？”或比较原文中的不同选择。回答不会自动保存为笔记。</Empty>}{messages.map(m => <article key={m.id} className={`nt-message ${m.role}`}>
      <div className="nt-message-heading"><span>{m.role === 'user' ? '我' : 'AI · 示例回答'}</span>{m.role === 'assistant' && <div className="nt-answer-actions">{multi && <label className="nt-check"><input type="checkbox" aria-label={`选择回答 ${excerpt(m.text, 20)}`} checked={selected.includes(m.id)} onChange={e => setSelected(s => e.target.checked ? [...s, m.id] : s.filter(id => id !== m.id))}/>合并</label>}<Button icon="save" variant="quiet" aria-label="保存此回答" onClick={() => setMenuId(menuId === m.id ? null : m.id)}>保存</Button>{menuId === m.id && <div className="nt-answer-menu nt-menu"><button onClick={() => requestSave(m.text)}>完整回答</button><button onClick={() => requestSave(m.text, 'source')}>选择 Markdown 片段</button><button onClick={() => { setMulti(true); setSelected(s => s.includes(m.id) ? s : [...s, m.id]); setMenuId(null); }}>选择多条回答</button></div>}</div>}</div>
      {m.scope?<FrozenScope snapshot={m.scope} compact/>:null}
      <div onMouseUp={() => m.role === 'assistant' && captureSelection(m.id)}><Markdown text={m.text}/></div>
      {semanticSelection?.id === m.id && <div className="nt-selection-tools"><span>已选 {semanticSelection.text.length} 字 · 渲染文本</span><Button icon="save" variant="quiet" onClick={() => requestSave(semanticSelection.text, 'selection')}>保存选段</Button><Button icon="file" variant="quiet" onClick={() => requestSave(m.text, 'source')}>含公式？选源文</Button><Button icon="close" variant="quiet" aria-label="关闭回答选段工具" onClick={() => setSemanticSelection(null)}/></div>}
      {m.role === 'assistant' && (m.scope?.kind==='notes'?<details className="nt-citation"><summary>本次笔记来源 · {m.scope.noteTitles.length} 篇</summary>{m.scope.noteTitles.map((title,i)=><Button key={m.scope.noteIds[i]} icon="notes" variant="quiet" onClick={()=>navigate('notes',{selectedDocId:m.scope.noteIds[i]})}>{title}</Button>)}</details>:<details className="nt-citation"><summary>原文依据 · 第 {(m.source||sourceFor(book)).page} 页</summary><p>{(m.source||sourceFor(book)).text}</p><Button icon="return" variant="quiet" onClick={()=>navigate('reader',{page:(m.source||sourceFor(book)).page,source:m.source||sourceFor(book)})}>返回原句</Button></details>)}
    </article>)}{busy && <p className="nt-status" role="status"><Icon name="sparkle"/>正在准备示例回答…</p>}</main>
    <div className="nt-chat-bottom">{multi && <div className="nt-merge-bar"><span>已选 {selected.length} 条回答 · 按会话顺序合并</span><Button variant="quiet" onClick={() => { setMulti(false); setSelected([]); }}>取消</Button><Button icon="save" variant="primary" disabled={!selected.length} onClick={() => requestSave(merged, 'merge')}>合并保存</Button></div>}<form className="nt-composer" onSubmit={e => { e.preventDefault(); send(); }}><textarea aria-label="向这本书提问" placeholder="问一个与这段原文有关的问题…" rows={2} value={question} onChange={e => setQuestion(e.target.value)} onKeyDown={e => { if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) { e.preventDefault(); send(); } }}/><Button type="submit" variant="primary" icon="arrowRight" disabled={!question.trim() || busy} aria-label="发送问题">{busy ? '等待中' : '发送'}</Button></form><div className="chat-scope-footer"><ScopePicker label="提问范围"/><small>翻页不会改变已发送的问题</small></div><p className="nt-prototype-note">本地交互演示 · 不调用模型，不消耗额度</p></div>
    {saveRequest && <SaveAnswerModal request={saveRequest} onClose={() => setSaveRequest(null)} onSaved={id => update({ selectedDocId: id })}/>}
  </section>;
}

export function KnowledgePage() {
  const { state, update, navigate, notify, confirm, book } = useApp();
  const [category, setCategory] = useState('notes');
  const [query, setQuery] = useState('');
  const [expanded, setExpanded] = useState(false);
  const [saveRequest, setSaveRequest] = useState(null);
  const docs = state.documents.filter(d => d.bookId === state.currentBookId && !d.deleted);
  const analysis = book.id === 'history' ? { title: '赤壁之战：条件、方案与结果', text: '连船提供了火攻的条件。黄盖提出建议，周瑜组织执行。把原文事实与推断分开，才能读清战局。' } : { title: '行变换：保留约束与可逆性', text: '三个合法的初等行变换均可逆，因而保存解集。证明时要同时说明变换和逆变换。' };
  const types = (state.typeDefinitions || []).filter(t => t.bookId === state.currentBookId);
  const match = (text) => !query || text.toLowerCase().includes(query.toLowerCase());
  const docRows = docs.filter(d => match(`${d.title} ${d.markdown}`));
  const typeRows = types.filter(t => match(`${t.name} ${(t.fields || []).join(' ')}`));
  const show = (key) => !!query || key === category;
  const trash = async doc => { if (await confirm({ title: '移入回收站？', body: `“${doc.title}”可从回收站恢复；导图节点会暂时隐藏。`, confirmLabel: '移入回收站', danger: true })) { update(prev => ({ ...prev, documents: prev.documents.map(d => d.id === doc.id ? { ...d, deleted: true } : d) })); notify('笔记已移入回收站。'); } };
  const addNode = doc => { update(prev => ({ ...prev, graphNodes: prev.graphNodes.some(n => n.docId === doc.id) ? prev.graphNodes : [...prev.graphNodes, makeNode(doc.id, doc.bookId, prev.graphNodes.length)] })); notify('已加入导图，引用原文档。'); };
  const noResults = !docRows.length && !typeRows.length && !match(`${analysis.title} ${analysis.text}`);
  return <section className="nt-page nt-knowledge-page" aria-label="知识库"><div className="nt-content-header"><div><span className="nt-eyebrow">这本书留下的内容</span><h1>知识库</h1></div><Button icon="plus" onClick={() => { update({ noteDraftRequest: Date.now() }); navigate('notes'); }}>写下理解</Button></div><Toolbar className="nt-knowledge-toolbar"><div className="nt-segment" aria-label="知识分类">{[['notes','笔记'],['analysis','分析'],['types','要素']].map(([key, label]) => <button key={key} className={!query && category === key ? 'active' : ''} disabled={!!query} onClick={() => setCategory(key)}>{label}</button>)}</div><label className="nt-search"><Icon name="search"/><input aria-label="搜索全部知识内容" placeholder="搜索全部内容…" value={query} onChange={e => setQuery(e.target.value)}/>{query && <button aria-label="清空知识搜索" onClick={() => setQuery('')}><Icon name="close" size={16}/></button>}</label><span className="tool-divider"/><Button icon="plus" aria-label="写下理解" title="写下理解" onClick={()=>navigate('notes',{noteDraftRequest:Date.now()})}/></Toolbar>{query && <p className="nt-muted">正在搜索笔记、AI 分析与要素，清空后恢复分类浏览。</p>}
      <main className="nt-knowledge-results">{show('notes') && <section><h2>用户笔记 <span>{docRows.length}</span></h2>{docRows.map(doc => <article className="nt-knowledge-row" key={doc.id}><button className="nt-open-doc" onClick={() => navigate('notes', { selectedDocId: doc.id })}><Icon name="file" size={24}/><span><strong>{doc.title}</strong><small>{excerpt(doc.markdown)}</small></span><Icon name="arrowRight" size={18}/></button><div className="nt-row-actions"><Button icon="mindmap" variant="quiet" aria-label={`把${doc.title}加入导图`} onClick={() => addNode(doc)}/><Button icon="trash" variant="quiet" aria-label={`将${doc.title}移入回收站`} onClick={() => trash(doc)}/></div></article>)}{!docRows.length && <p className="nt-empty-small">{query ? '没有匹配笔记' : '还没有笔记。主动保存回答，或写下自己的理解。'}</p>}</section>}
      {show('analysis') && match(`${analysis.title} ${analysis.text}`) && <section><h2>阅读分析 <span>AI 内容</span></h2><article className="nt-analysis-row"><button className="nt-analysis-toggle" aria-expanded={expanded} onClick={() => setExpanded(v => !v)}><span><strong>{analysis.title}</strong><small>保留原文依据，与用户笔记分开</small></span><Icon name="chevronDown" style={{ transform: expanded ? 'rotate(180deg)' : '' }}/></button>{expanded && <div className="nt-analysis-expanded"><Markdown text={analysis.text}/><SourceQuote source={sourceFor(book)} onReturn={() => navigate('reader', { source: sourceFor(book) })}/><Button icon="save" onClick={() => setSaveRequest({ title: analysis.title, markdown: analysis.text })}>另存为我的 Markdown</Button></div>}</article></section>}
      {show('types') && <section><h2>书中要素 <span>按书定义</span></h2><div className="nt-type-grid">{typeRows.map(type => <button key={type.id} className="nt-type-card" onClick={() => navigate('cards')}><Icon name="cards"/><strong>{type.name}</strong><small>{type.fields.join(' · ')}</small><span>查看此类型要素 <Icon name="arrowRight" size={16}/></span></button>)}</div>{!typeRows.length && <p className="nt-empty-small">这本书还没有匹配的要素类型，数学书不会强制建立人物卡。</p>}</section>}{query && noResults && <Empty icon="search" title="没有找到匹配内容">换一个关键词，或清空搜索查看已有内容。</Empty>}</main>{saveRequest && <SaveAnswerModal request={saveRequest} onClose={() => setSaveRequest(null)} onSaved={id => update({ selectedDocId: id })}/>}</section>;
}

export function SearchPanel({embedded=false}) {
  const { state, update, navigate, notify, book } = useApp();
  const [query, setQuery] = useState('');
  const [scope, setScope] = useState('book');
  const [busy, setBusy] = useState(false);
  const close = () => update({ searchOpen: false });
  const sources = [
    { id: 'sm1', bookId: 'math', bookTitle: '线性代数 · 习题解析', page: 1, chapter: '线性方程组', text: '行变换不改变方程组的解集。先消去第一列，再寻找主元。', object: '初等行变换' },
    { id: 'sm2', bookId: 'math', bookTitle: '线性代数 · 习题解析', page: 3, chapter: '主元与自由变量', text: '主元所在的列决定基本变量，其余变量为自由变量。', object: '主元' },
    ...SPATIAL_EVENTS.filter(event => event.quote).map(event => ({ id: event.id, bookId: 'history', bookTitle: '三国演义', ...event.source, object: `${event.name} · ${event.people.join('、')}` }))
  ];
  useEffect(() => { if (!query) { setBusy(false); return; } setBusy(true); const id = setTimeout(() => setBusy(false), 240); return () => clearTimeout(id); }, [query, scope]);
  const results = query.trim() ? sources.filter(s => !(state.deletedBookIds || []).includes(s.bookId) && (scope === 'library' || s.bookId === state.currentBookId) && `${s.text} ${s.chapter} ${s.object}`.includes(query.trim())) : [];
  const follow = async result => { const accepted = await navigate('reader', { currentBookId: result.bookId, source: { page: result.page, paragraph: result.paragraph || 2, chapter: result.chapter, text: result.text }, page: result.page }); if (accepted !== false) close(); };
  const content=<div className="nt-library-search"><div className="nt-segment" aria-label="原文搜索范围"><button className={scope === 'book' ? 'active' : ''} onClick={() => setScope('book')}>这本书</button><button className={scope === 'library' ? 'active' : ''} onClick={() => setScope('library')}>整个书库</button></div><label className="nt-search"><Icon name="search"/><input autoFocus aria-label="搜索原文关键词" placeholder="查找原文、章节或对象别名…" value={query} onChange={e => setQuery(e.target.value)}/>{query && <button aria-label="清空原文搜索" onClick={() => setQuery('')}><Icon name="close" size={16}/></button>}</label><p className="nt-muted">离线示例索引，不调用 AI，不搜索私人笔记正文。</p><div className="nt-search-results">{busy ? <p className="nt-status" role="status">正在检索…</p> : !query ? <Empty icon="search" title="沿原文寻找线索">试试“行变换”“主元”，或切换书库搜索“赤壁”。</Empty> : !results.length ? <Empty icon="search" title="没有找到匹配原文">扫描页尚未 OCR 时不会进入文字索引。试试更短的词。</Empty> : <><p className="nt-muted">{results.length} 处原文 · {new Set(results.map(r => r.bookId)).size} 本书</p>{results.map(r => <button className="nt-search-result" key={r.id} onClick={() => follow(r)}><span>{r.bookTitle} · 第 {r.page} 页 · {r.chapter}</span><strong>{r.object}</strong><p>{r.text}</p><small>返回这段原文 <Icon name="arrowRight" size={16}/></small></button>)}</>}</div></div>;return embedded?content:<Modal title="搜索原文与书库" onClose={close}>{content}</Modal>;
}

export function TrashPage() {
  const { state, update, navigate, notify } = useApp();
  const [query, setQuery] = useState('');
  const [restoring, setRestoring] = useState(null);
  const deletedBooks = books.filter(book => (state.deletedBookIds || []).includes(book.id));
  const bookRows = deletedBooks.filter(book => `${book.title} ${book.author}`.toLowerCase().includes(query.toLowerCase()));
  const deleted = state.documents.filter(d => d.deleted);
  const rows = deleted.filter(d => `${d.title} ${d.markdown}`.toLowerCase().includes(query.toLowerCase()));
  const restore = async doc => { setRestoring(doc.id); await new Promise(r => setTimeout(r, 280)); update(prev => ({ ...prev, documents: prev.documents.map(d => d.id === doc.id ? { ...d, deleted: false } : d) })); setRestoring(null); notify('已恢复笔记，原有导图节点与连接一同恢复显示。'); };
  const restoreBook = async book => { setRestoring(`book-${book.id}`); await new Promise(r => setTimeout(r, 280)); update(prev => ({ ...prev, deletedBookIds: (prev.deletedBookIds || []).filter(id => id !== book.id) })); setRestoring(null); notify('书籍已恢复，原书、笔记与关联保持不变。'); };
  return <section className="nt-page nt-trash-page" aria-label="回收站"><div className="nt-content-header"><div><span className="nt-eyebrow">恢复自己的内容</span><h1>回收站</h1></div><Button icon="return" onClick={() => navigate('notes')}>回到笔记</Button></div><p className="nt-trash-explainer">书籍与 Markdown 都可恢复。笔记保留文档身份，恢复后，导图中的原节点和连接也会重新出现。</p><label className="nt-search"><Icon name="search"/><input aria-label="搜索回收内容" placeholder="搜索已回收书籍或笔记…" value={query} onChange={e => setQuery(e.target.value)}/>{query && <button aria-label="清空回收站搜索" onClick={() => setQuery('')}><Icon name="close" size={16}/></button>}</label><main className="nt-trash-list">{!!bookRows.length && <section aria-label="已回收书籍"><h2 className="nt-trash-group-title">书籍</h2>{bookRows.map(book => <article key={book.id} className="nt-trash-row"><Icon name="book" size={28}/><div><h2>{book.title}</h2><p>{book.author} · 已回收书籍</p><span>原书、用户笔记与关联数据仍保留</span></div><Button icon="undo" disabled={!!restoring} onClick={() => restoreBook(book)}>{restoring === `book-${book.id}` ? '恢复中…' : '恢复书籍'}</Button></article>)}</section>}{!!rows.length && <section aria-label="已回收笔记"><h2 className="nt-trash-group-title">Markdown 笔记</h2>{rows.map(doc => <article key={doc.id} className="nt-trash-row"><Icon name="file" size={28}/><div><h2>{doc.title}</h2><p>{doc.bookId === 'history' ? '三国演义' : '线性代数 · 习题解析'} · Markdown 笔记</p><span>{excerpt(doc.markdown, 85)}</span></div><Button icon="undo" disabled={!!restoring} onClick={() => restore(doc)}>{restoring === doc.id ? '恢复中…' : '恢复'}</Button></article>)}</section>}{!rows.length && !bookRows.length && <Empty icon="trash" title={query ? '没有匹配的回收内容' : '回收站是空的'}>{query ? '换一个关键词试试。' : '删除的书籍和笔记会先来到这里，不会直接消失。'}</Empty>}</main><aside className="nt-recovery-note"><Icon name="info" size={20}/><span>此处恢复书籍与 Markdown。高亮批注、伴读条目在各自面板恢复；移除导图节点只改变布局，不删除文档。派生要素和服务配置另有删除规则。</span></aside></section>;
}
