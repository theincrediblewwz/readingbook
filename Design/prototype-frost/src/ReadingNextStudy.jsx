import React, { memo, useEffect, useLayoutEffect, useRef, useState } from 'react';
import { Icon } from './shared.jsx';
import './reading-next.css';

const components = [{ id: 'map', title: '时间与地图', detail: '人物、事件与行迹' }, { id: 'mindmap', title: '思维导图', detail: '章节、笔记与线索' }, { id: 'relations', title: '关系图谱', detail: '人物与势力的联系' }, { id: 'cards', title: '人物与术语', detail: '边读边查，优先复用' }];
const steps = [{ id: 'read', title: '读懂这一部分', fixed: true }, { id: 'people', title: '人物、事件与联系' }, { id: 'translation', title: '需要时补充译注' }, { id: 'review', title: '章节回顾与未解问题' }, { id: 'receipts', title: '逐段复述与核对', fine: true }];
const groups = [{ title: '人物', count: 4, names: ['贾诩', '董卓', '丁原', '李傕'] }, { title: '地点', count: 3, names: ['长安', '洛阳', '凉州'] }, { title: '事件', count: 2, names: ['局势的变化', '人物的选择'] }, { title: '术语', count: 3, names: ['诏书', '太师', '矫诏'] }];
const history = [{ title: '整理人物与联系', range: '第九回 · 当前片段', status: '已保存', time: '刚刚', objects: ['复用人物：贾诩', '新增原文提及：1 处', '更新人物关系：2 条'] }, { title: '组装本书组件', range: '全书阅读方案', status: '已保存', time: '2 分钟前', objects: ['时间与地图：已启用', '思维导图：已启用', '人物与术语：已启用', '绑定本书已有实体与事件；地图暂无明确坐标的事件保持待定位。'] }, { title: '准备第九回译注', range: '第九回 · 3 个句段', status: '已保存', time: '4 分钟前', objects: ['新增译注：3 处', '已连接到对应原句，可在阅读页悬停查看。'] }];
const clamp = (x, min, max) => Math.max(min, Math.min(max, x));

function Control({ icon, children, label, active = false, primary = false, ...props }) {
  return <button type="button" className={`rn-control ${active ? 'active' : ''} ${primary ? 'primary' : ''} ${children ? '' : 'icon'}`} aria-label={label} title={label} {...props}>{icon && <Icon name={icon} size={19} />}{children}</button>;
}

function Dialog({ title, icon, close, children, footer, className = '' }) {
  const ref = useRef(null);
  useEffect(() => {
    const previous = document.activeElement;
    ref.current?.focus();
    return () => previous?.focus?.();
  }, []);
  function key(event) {
    if (event.key === 'Escape') { event.preventDefault(); close(); }
    if (event.key !== 'Tab') return;
    const nodes = [...ref.current.querySelectorAll('button:not(:disabled), input, select, textarea, [tabindex="0"]')];
    const first = nodes[0], last = nodes.at(-1);
    if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
    else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
  }
  return <div className="rn-scrim" onPointerDown={e => { if (e.target === e.currentTarget) close(); }}><section className={`rn-dialog rn-surface ${className}`} role="dialog" aria-modal="true" aria-label={title} tabIndex={-1} ref={ref} onKeyDown={key}>
    <header><h2><Icon name={icon} />{title}</h2><Control icon="close" label={`关闭${title}`} onClick={close} /></header>
    <div className="rn-dialog-body">{children}</div>{footer && <footer>{footer}</footer>}
  </section></div>;
}

const Page = memo(function Page({ onHover, onLeave, onTerm }) {
  return <article className="rn-page" aria-label="示例原文"><p className="rn-chapter">三国演义 · 第九回</p><h1>犯长安李傕听贾诩</h1><p className="rn-intro">原文节选</p>
    <p>且说李傕、郭汜、张济、樊稠逃居陕西，使人至长安上表求赦。王允曰：“卓之跋扈，皆此四人助之；今虽大赦天下，独不赦此四人。”</p>
    <p>使者回报李傕。傕曰：“求赦不得，各自逃生可也。”谋士<button className="rn-term" onClick={e => onTerm(e.currentTarget.getBoundingClientRect())}>贾诩</button>曰：<span className="rn-source-sentence" tabIndex={0} aria-label="诸君若弃军单行，则一亭长能缚君矣，按回车查看译注" onMouseEnter={e => onHover(e.currentTarget.getBoundingClientRect())} onMouseLeave={onLeave} onFocus={e => onHover(e.currentTarget.getBoundingClientRect())} onKeyDown={e => { if (e.key === 'Enter') onHover(e.currentTarget.getBoundingClientRect(), true); }} onClick={e => onHover(e.currentTarget.getBoundingClientRect(), true)}>“诸君若弃军单行，则一亭长能缚君矣。</span>不若诱集陕人，并本部军马，杀入长安，与董卓报仇。事济，奉朝廷以正天下；若其不胜，走亦未迟。”</p>
    <p>傕等然其说，遂流言于西凉州曰：“王允将欲洗荡此方之人矣。”众皆惊惶。乃复扬言曰：“徒死无益，能从我反乎？”众皆愿从。</p>
    <div className="rn-reader-note"><Icon name="info" size={17} /><span>公共领域<a href="https://zh.wikisource.org/zh-hans/三國演義/第009回" target="_blank" rel="noreferrer">原文节选</a>。讲解、译注与任务均为交互示例。</span></div>
  </article>;
});

function Companion({ close, openTask, visible }) {
  const ref = useRef(null), drag = useRef(null), dimensions = useRef(null);
  const [tab, setTab] = useState('chat'), [context, setContext] = useState('pure'), [voice, setVoice] = useState('teacher');
  const [group, setGroup] = useState(null), [selected, setSelected] = useState(null), [question, setQuestion] = useState(''), [messages, setMessages] = useState([]), [sending, setSending] = useState(false), [expanded, setExpanded] = useState(false), [size, setSize] = useState(16);
  const visibleMessages = messages.filter(message => message.context === context);
  const timer = useRef(null);
  useEffect(() => () => clearTimeout(timer.current), []);
  useEffect(() => {
    function fit() {
      if (!visible || expanded || !ref.current) return;
      const node = ref.current, stage = node.parentElement.getBoundingClientRect(), rect = node.getBoundingClientRect();
      const width = Math.min(rect.width, stage.width - 32), height = Math.min(rect.height, stage.height - 168);
      node.style.width = `${width}px`; node.style.height = `${height}px`; node.style.right = 'auto';
      node.style.left = `${clamp(rect.left - stage.left, 16, stage.width - width - 16)}px`;
      node.style.top = `${clamp(rect.top - stage.top, 80, stage.height - height - 88)}px`;
    }
    if (visible) fit();
    window.addEventListener('resize', fit); return () => window.removeEventListener('resize', fit);
  }, [expanded, visible]);
  function start(event, resizing = false) {
    if (expanded || (event.button !== 0) || (!resizing && event.target.closest('button,select'))) return;
    const node = ref.current, stage = node.parentElement.getBoundingClientRect(), rect = node.getBoundingClientRect();
    drag.current = { x: event.clientX, y: event.clientY, left: rect.left - stage.left, top: rect.top - stage.top, width: rect.width, height: rect.height, stage, resizing };
    event.currentTarget.setPointerCapture(event.pointerId); event.preventDefault();
  }
  function move(event) {
    const value = drag.current; if (!value) return;
    const node = ref.current, dx = event.clientX - value.x, dy = event.clientY - value.y;
    if (value.resizing) {
      const right = value.left + value.width;
      const width = clamp(value.width - dx, Math.min(330, value.stage.width - 32), Math.min(760, right - 16));
      node.style.left = `${right - width}px`; node.style.right = 'auto'; node.style.width = `${width}px`; node.style.height = `${clamp(value.height + dy, 330, value.stage.height - value.top - 88)}px`;
    } else {
      node.style.right = 'auto'; node.style.left = `${clamp(value.left + dx, 16, value.stage.width - value.width - 16)}px`; node.style.top = `${clamp(value.top + dy, 80, value.stage.height - value.height - 88)}px`;
    }
  }
  function end(event) {
    const value = drag.current; if (!value) return;
    if (!value.resizing) {
      const node = ref.current, rect = node.getBoundingClientRect(), x = rect.left - value.stage.left, y = rect.top - value.stage.top;
      const anchors = [[16, 80], [value.stage.width - rect.width - 16, 80], [16, value.stage.height - rect.height - 88], [value.stage.width - rect.width - 16, value.stage.height - rect.height - 88], [(value.stage.width - rect.width) / 2, value.stage.height - rect.height - 88]];
      const nearest = anchors.reduce((a, b) => Math.hypot(a[0] - x, a[1] - y) < Math.hypot(b[0] - x, b[1] - y) ? a : b);
      node.style.left = `${Math.max(16, nearest[0])}px`; node.style.top = `${Math.max(80, nearest[1])}px`;
    }
    drag.current = null; if (event.currentTarget.hasPointerCapture(event.pointerId)) event.currentTarget.releasePointerCapture(event.pointerId);
  }
  function toggleExpanded() {
    const node = ref.current;
    if (!expanded) { dimensions.current = node.getAttribute('style'); node.removeAttribute('style'); }
    else if (dimensions.current) node.setAttribute('style', dimensions.current);
    setExpanded(value => !value);
  }
  function send(event) {
    event.preventDefault(); if (!question.trim() || sending) return;
    const text = question.trim(); setQuestion(''); setSending(true); setMessages(prev => [...prev, { text, role: 'user', context, voice }]);
    timer.current = setTimeout(() => { setMessages(prev => [...prev, { role: 'assistant', context, voice, text: voice === 'teacher' ? '我们先把注意力放回这句话：人物的建议为什么会被听取？可以一边看他的处境，一边看这次选择把故事带向哪里。这里是示例回答，真正运行时会结合你选的原文。' : '这一片段可以确认的是人物的出现与这次建议。具体经历需要核对相应正文；示例不会补成原文事实。' }]); setSending(false); }, 600);
  }
  return <aside ref={ref} hidden={!visible} className={`rn-companion rn-surface ${expanded ? 'expanded' : ''}`} aria-label="伴读与对话">
    <header className="rn-drag" onPointerDown={start} onPointerMove={move} onPointerUp={end} onPointerCancel={end}><h2><Icon name="sparkle" />伴读与对话</h2><div><Control icon={expanded ? 'return' : 'expand'} label={expanded ? '还原伴读大小' : '放大阅读'} onClick={toggleExpanded} /><Control icon="minus" label="收起伴读" onClick={close} /></div></header>
    <div className="rn-tabs" role="tablist" aria-label="伴读内容"><button role="tab" aria-selected={tab === 'read'} onClick={() => setTab('read')}>伴读</button><button role="tab" aria-selected={tab === 'chat'} onClick={() => setTab('chat')}>对话</button></div>
    <div className="rn-modebar"><label><span className="sr-only">讲解风格</span><select aria-label="讲解风格" value={voice} onChange={e => setVoice(e.target.value)}><option value="teacher">老师伴读</option><option value="evidence">原文考据</option></select></label>{tab === 'chat' ? <label><span className="sr-only">对话模式</span><select aria-label="对话模式" value={context} onChange={e => setContext(e.target.value)}><option value="pure">纯阅读</option><option value="tools">功能协作</option></select></label> : <span className="rn-muted">当前页</span>}<div className="rn-font"><Control label="减小内容字号" onClick={() => setSize(v => Math.max(14, v - 1))}>A−</Control><Control label="增大内容字号" onClick={() => setSize(v => Math.min(22, v + 1))}>A＋</Control></div></div>
    {tab === 'chat' ? <><div className="rn-chat-scroll" style={{ '--reading-size': `${size}px` }}>
      {!visibleMessages.length ? <div className="rn-chat-welcome"><Icon name="chat" size={32} /><h3>像和懂书的人坐在一起。</h3><p>{context === 'pure' ? '带上眼前的原文，聊你真正想问的事。' : '讨论内容，也可以一起整理这本书。'}</p><button className="rn-suggestion" onClick={() => setQuestion('这里的贾诩是谁？')}>这里的贾诩是谁？</button></div> : visibleMessages.map((message, index) => <div key={index} className={`rn-message ${message.role}`}><p>{message.text}</p>{message.role === 'assistant' && <div className="rn-message-actions"><Control icon="quote" label="查看本次查阅" onClick={openTask}>本次查阅</Control><Control icon="notes" label="保存这条示例回答" onClick={() => setSelected('回答已选中，可保存为新笔记（示例）')} /></div>}</div>)}
      {sending && <p className="rn-small-status" role="status"><Icon name="sparkle" size={16} />正在读这一段…</p>}
      {selected && <div className="rn-inline-note" role="status">{selected}</div>}
    </div><form className="rn-composer" onSubmit={send}><textarea aria-label="向伴读提问" placeholder="关于这一段，你想聊什么？" value={question} onChange={e => setQuestion(e.target.value)} /><div><span><Icon name="book" size={16} />当前页</span><Control icon="arrowRight" primary label="发送问题" type="submit" disabled={!question.trim() || sending} /></div></form></> : <div className="rn-groups" style={{ '--reading-size': `${size}px` }}><p className="rn-muted rn-group-caption">这一页已有的线索</p>{groups.map(item => <section key={item.title}><button className="rn-group-row" aria-expanded={group === item.title} onClick={() => { setGroup(group === item.title ? null : item.title); setSelected(null); }}><Icon name="cards" /><span>{item.title}</span><small>{item.count}</small><Icon name={group === item.title ? 'chevronDown' : 'chevronRight'} size={16} /></button>{group === item.title && <div className="rn-group-items">{item.names.map(name => <button key={name} onClick={() => setSelected(name)}>{name}<Icon name="chevronRight" size={14} /></button>)}{selected && item.names.includes(selected) && <div className="rn-object-copy"><h3>{selected}</h3><p>{voice === 'teacher' ? '先从这次出场认识他，再沿着你读到的情节慢慢补全。已有介绍会优先复用。' : '查看这一页的原文出现处与已经核对的依据。'}</p><span className="rn-muted">本地已有介绍 · 示意</span></div>}</div>}</section>)}<button className="rn-translation-row" onClick={() => setGroup(group === 'translations' ? null : 'translations')}><Icon name="book" />句旁译注<small>3</small><Icon name="chevronRight" size={16} /></button>{group === 'translations' && <p className="rn-object-copy">把鼠标停在原句上，译注就会出现在旁边。也可点击原句固定查看。</p>}</div>}
    {!expanded && <button className="rn-resize" aria-label="拖动调整伴读大小" onPointerDown={e => start(e, true)} onPointerMove={move} onPointerUp={end} onPointerCancel={end}><Icon name="expand" size={16} /></button>}
  </aside>;
}

function Plan({ close, selection, setSelection, paused, setPaused, setApplied, notify, saved, save }) {
  const [range, setRange] = useState(saved.range), [start, setStart] = useState(saved.start), [end, setEnd] = useState(saved.end);
  const [detail, setDetail] = useState(saved.detail), [enabled, setEnabled] = useState(saved.enabled), [limit, setLimit] = useState(saved.limit);
  const [chosen, setChosen] = useState(selection), [custom, setCustom] = useState(saved.custom), [newStep, setNewStep] = useState(''), [addingStep, setAddingStep] = useState(false);
  const valid = range !== 'pages' || (+start >= 1 && +end >= +start && +end <= 1484 && Number.isInteger(+start) && Number.isInteger(+end));
  const flip = (id, list, update) => update(list.includes(id) ? list.filter(v => v !== id) : [...list, id]);
  function addStep() { if (!newStep.trim()) return; const item = { id: `custom-${Date.now()}`, title: newStep.trim() }; setCustom(prev => [...prev, item]); setEnabled(prev => [...prev, item.id]); setNewStep(''); setAddingStep(false); }
  return <Dialog title="按你的方式读" icon="sparkle" close={close} className="rn-plan" footer={<><span className="rn-muted">示例操作，不会调用模型</span><Control primary icon="check" disabled={!valid} onClick={() => { const title = range === 'book' ? '整本书' : range === 'pages' ? `第 ${start}–${end} 页` : '当前章'; setSelection(chosen); save({range,start,end,detail,enabled,limit,custom}); setApplied(title); setPaused(false); notify(`已按${title}继续，已有结果保留（示例）`); close(); }}>{paused ? '应用范围并继续' : '确认阅读方案'}</Control></>}>
    <section><h3>这次读多少</h3><div className="rn-choice-row">{[['chapter', '当前章'], ['pages', '指定页码'], ['book', '整本书']].map(([id, text]) => <Control key={id} active={range === id} onClick={() => setRange(id)}>{text}</Control>)}</div>{range === 'pages' && <div className="rn-page-range"><label>从 <input aria-label="起始页" type="number" min="1" max="1484" value={start} onChange={e => { setStart(e.target.value); if (+e.target.value > +end) setEnd(e.target.value); }} /></label><span>到</span><input aria-label="结束页" type="number" min={start} max="1484" value={end} onChange={e => setEnd(e.target.value)} /><span>页</span></div>}</section>
    <section><h3>怎么安排节奏</h3><div className="rn-choice-row">{[['auto', 'AI 自适应'], ['page', '逐页'], ['chapter', '按章节']].map(([id, text]) => <Control key={id} active={detail === id} onClick={() => setDetail(id)}>{text}</Control>)}</div><p className="rn-muted">范围决定读哪里；节奏决定每次读多少。长章仍会分成合适的片段。</p></section>
    <section><h3>你希望用上的组件</h3><div className="rn-component-grid">{components.map(item => <button key={item.id} aria-pressed={chosen.includes(item.id)} className={chosen.includes(item.id) ? 'selected' : ''} onClick={() => flip(item.id, chosen, setChosen)}><Icon name={item.id} size={23} /><span><strong>{item.title}</strong><small>{item.detail}</small></span><Icon name={chosen.includes(item.id) ? 'check' : 'plus'} size={18} /></button>)}</div></section>
    <section><h3>保留哪些分析</h3><div className="rn-step-choices">{[...steps,...custom].map(step => <label key={step.id}><input type="checkbox" checked={enabled.includes(step.id)} disabled={step.fixed} onChange={() => flip(step.id, enabled, setEnabled)} /><span>{step.title}</span>{step.fine && <small>精读可选</small>}</label>)}</div>{addingStep ? <div className="rn-add-step"><input aria-label="自定义分析步骤" placeholder="你还关心什么？" value={newStep} onChange={e=>setNewStep(e.target.value)} onKeyDown={e=>{if(e.key==='Enter')addStep();}} maxLength={120}/><Control icon="plus" label="确认添加步骤" onClick={addStep} disabled={!newStep.trim()}/></div> : <Control icon="plus" onClick={()=>setAddingStep(true)}>添加步骤</Control>}<p className="rn-muted">章节回顾只在章末做；关闭逐段核对不会冒充已经精读。</p></section>
    <section className="rn-parallel-setting"><div><h3>同时做几件事</h3><p className="rn-muted">AI 建议 3 路，优先为当前提问留出位置。</p></div><select aria-label="并行任务上限" value={limit} onChange={e => setLimit(e.target.value)}>{[1, 2, 3, 4, 5].map(n => <option key={n} value={n}>最多 {n} 路</option>)}</select></section>
  </Dialog>;
}

function Tasks({ close, paused, setPaused, applied, plan }) {
  const [selected, setSelected] = useState(null);
  return <Dialog title="阅读正在发生" icon="clock" close={close} className="rn-task-dialog" footer={<><Control icon="models" onClick={plan}>调整范围与步骤</Control><Control icon={paused ? 'play' : 'pause'} primary onClick={() => setPaused(v => !v)}>{paused ? '继续分析' : '暂停分析'}</Control></>}>
    <div className="rn-task-summary"><div><span className="rn-eyebrow">{paused ? '已暂停，已有结果保留' : '后台分析 · 示例'}</span><h3>{applied}</h3><p>全书已有 18 页结果，缩小范围也会保留。</p></div><span className="rn-task-fraction">18<small> 页已有结果</small></span></div>
    <div className="rn-task-lanes"><span><Icon name={paused ? 'pause' : 'sparkle'} />{paused ? '等待继续' : '整理所选内容'}</span><span><Icon name="chat" />对话随时可用</span></div>
    <div className="rn-history-heading"><h3>本次记录</h3><span>收到思考 6,420 · 输出 1,180 字符</span></div>
    {history.map((item, index) => <section className="rn-history-item" key={item.title}><button aria-expanded={selected === index} onClick={() => setSelected(selected === index ? null : index)}><Icon name="check" /><span><strong>{item.title}</strong><small>{item.range}</small></span><small>{item.time}</small><Icon name={selected === index ? 'chevronDown' : 'chevronRight'} size={16} /></button>{selected === index && <div className="rn-history-detail"><span className="rn-result-tag">{item.status} · 示例回执</span>{item.objects.map(text => <p key={text}>{text}</p>)}<dl><dt>结果位置</dt><dd>本书组件 / 伴读</dd><dt>请求</dt><dd>本次第 {3 - index} 次 · 仅示意</dd></dl></div>}</section>)}
  </Dialog>;
}

export default function ReadingNextStudy() {
  const [nav, setNav] = useState(false), [modal, setModal] = useState(null), [companion, setCompanion] = useState(() => window.innerWidth >= 1100), [bubble, setBubble] = useState(null), [pinned, setPinned] = useState(false);
  const [paused, setPaused] = useState(false), [selection, setSelection] = useState(['map', 'mindmap', 'relations', 'cards']), [applied, setApplied] = useState('整本书'), [notice, setNotice] = useState('');
  const [planOptions, setPlanOptions] = useState({range:'book',start:'1',end:'20',detail:'auto',enabled:['read','people','translation','review'],limit:'3',custom:[]});
  const bubbleRef = useRef(null);
  const hover = useRef(null), hide = useRef(null), noticeTimer = useRef(null);
  useEffect(() => () => { clearTimeout(hover.current); clearTimeout(hide.current); clearTimeout(noticeTimer.current); }, []);
  useEffect(() => { function key(e) { if (e.key === 'Escape') { setBubble(null); setPinned(false); setNav(false); } } window.addEventListener('keydown', key); return () => window.removeEventListener('keydown', key); }, []);
  useLayoutEffect(() => {
    if (!bubble?.anchor || !bubbleRef.current) return;
    const node = bubbleRef.current, anchor = bubble.anchor, width = node.offsetWidth;
    let maxHeight = window.innerHeight - 120, x, y;
    if (anchor.right + 16 + width <= window.innerWidth - 16) x = anchor.right + 16;
    else if (anchor.left - width - 16 >= 16) x = anchor.left - width - 16;
    else {
      x = clamp(anchor.left, 16, window.innerWidth - width - 16);
      const above = anchor.top - 102, below = window.innerHeight - anchor.bottom - 28;
      maxHeight = Math.max(above, below);
      if (maxHeight < 100) { setBubble(null); setCompanion(true); return; }
      const height = Math.min(node.scrollHeight + 2, maxHeight);
      y = below >= above ? anchor.bottom + 12 : anchor.top - height - 12;
    }
    if (y === undefined) y = clamp(anchor.top - 20, 90, window.innerHeight - Math.min(node.scrollHeight + 2, maxHeight) - 16);
    setBubble(current => current ? { ...current, x, y, maxHeight } : current);
  }, [bubble?.anchor, bubble?.kind]);
  function notify(text) { clearTimeout(noticeTimer.current); setNotice(text); noticeTimer.current = setTimeout(() => setNotice(''), 3500); }
  function showBubble(rect, pin = false, kind = 'translation') {
    clearTimeout(hide.current); clearTimeout(hover.current);
    hover.current = setTimeout(() => {
      const width = Math.min(350, window.innerWidth - 32), height = kind === 'term' ? 430 : 160;
      let x = rect.right + 16, y = clamp(rect.top - 24, 120, window.innerHeight - height - 16);
      if (x + width > window.innerWidth - 16) {
        if (rect.left - width - 16 >= 16) x = rect.left - width - 16;
        else { x = clamp(rect.left, 16, window.innerWidth - width - 16); y = rect.bottom + 14; if (y + height > window.innerHeight - 16) y = Math.max(90, rect.top - height - 14); }
      }
      setBubble({ x, y, kind, anchor: {left:rect.left,right:rect.right,top:rect.top,bottom:rect.bottom} }); setPinned(pin);
    }, pin ? 0 : 260);
  }
  function leaveBubble() { clearTimeout(hover.current); if (!pinned) hide.current = setTimeout(() => setBubble(null), 240); }
  return <main className="rn-app"><div className="rn-reviewbar"><span>ReadingBook · 下一版交互稿</span><span className="rn-muted">本地示例 · 不连接模型或真实书库</span><div><Control icon="models" onClick={() => setModal('plan')}>阅读方案</Control><Control icon="clock" onClick={() => setModal('tasks')}>任务详情</Control></div></div>
    <div className="rn-stage"><div className="rn-reading-scene" inert={modal ? true : undefined}><header className="rn-top"><div className="rn-top-left rn-surface"><Control icon="sidebar" active={nav} label="展开功能导航" onClick={() => { setNav(v => !v); setBubble(null); }} /><Control icon="book" label="打开阅读目录" onClick={() => notify('第九回 · 当前片段；阅读目录沿用现有导航（示例）')} /><span className="rn-top-divider" /><span>三国演义</span></div><div className="rn-top-right"><Control icon="sparkle" primary onClick={() => setModal('plan')}>智能阅读</Control></div></header>
      <Page onHover={showBubble} onLeave={leaveBubble} onTerm={rect => showBubble(rect, true, 'term')} />
      {nav && <nav className="rn-navigation rn-surface" aria-label="阅读工作台"><header><h2><Icon name="book" />阅读工作台</h2><Control icon="close" label="收起功能导航" onClick={() => setNav(false)} /></header>{[['reader', '原文阅读'], ['map', '时间与地图'], ['mindmap', '思维导图'], ['relations', '关系图谱'], ['notes', '我的笔记']].filter(([id]) => id === 'reader' || id === 'notes' || selection.includes(id)).map(([icon, title]) => <button key={icon} onClick={() => { setNav(false); if (icon !== 'reader') notify(`${title}会与本书对象联动；此稿聚焦阅读现场。`); }}><Icon name={icon} />{title}</button>)}<hr /><button onClick={() => { setNav(false); setModal('plan'); }}><Icon name="plugins" />添加或调整组件</button><button onClick={() => { setNav(false); setModal('settings'); }}><Icon name="settings" />模型设置</button></nav>}
      <Companion visible={companion} close={() => setCompanion(false)} openTask={() => setModal('tasks')} />{!companion && <button className="rn-restore rn-surface" onClick={() => setCompanion(true)}><Icon name="chat" size={21} />伴读与对话</button>}
      <div className="rn-bottom-dock rn-surface"><Control icon="chevronLeft" label="示例上一页" onClick={() => notify('已回到上一页（示例）')} /><span>24 / 1484</span><Control icon="chevronRight" label="示例下一页" onClick={() => notify('已翻到下一页；先显示原文，再补充译注（示例）')} /><i /><Control icon="sparkle" label="打开伴读" active={companion} onClick={() => setCompanion(v => !v)} /><Control icon="highlight" label="示例批注" onClick={() => notify('手动批注继续保留原有保存链路。')} /></div>
      <span className="rn-reading-percent" aria-label="示例阅读位置">2%</span><button className="rn-background-status" onClick={() => setModal('tasks')}><Icon name={paused ? 'pause' : 'sparkle'} size={15} /><span>{paused ? '分析已暂停' : '18 页已有结果'}</span><Icon name="chevronRight" size={13} /></button>
      {bubble && !modal && <aside ref={bubbleRef} className={`rn-bubble rn-surface ${bubble.kind}`} style={{ left: bubble.x, top: bubble.y, maxHeight: bubble.maxHeight }} onMouseEnter={() => clearTimeout(hide.current)} onMouseLeave={leaveBubble} aria-label={bubble.kind === 'term' ? '人物释义' : '句旁译注'}><header><span>{bubble.kind === 'term' ? '人物 · 贾诩' : '句旁译注'}</span><div><Control icon={pinned ? 'check' : 'bookmark'} label={pinned ? '取消固定译注' : '固定译注'} onClick={() => setPinned(v => !v)} /><Control icon="close" label="关闭释义气泡" onClick={() => { setBubble(null); setPinned(false); }} /></div></header>{bubble.kind === 'term' ? <><h3>先看他眼前的局势。</h3><p>李傕等人想各自逃走，贾诩却先指出：一旦失去军队的保护，就很容易被抓住。他的建议，从重新聚拢力量开始。</p><span className="rn-source-tag">本段解读 · 示意</span><p className="rn-background-copy"><small>背景补充</small>贾诩字文和，武威姑臧人。不妨先留意他怎样衡量风险，再随着情节认识他。<a href="https://ctext.org/text.pl?if=en&amp;node=602422" target="_blank" rel="noreferrer">背景出处</a></p><div className="rn-mini-map"><img src="/assets/map-terrain.png" alt="内嵌地图元件的示例底图" /><span>地图排版示意 · 未虚构人物坐标</span></div><div className="rn-mini-time"><Icon name="clock" size={16} /><span>第九回 · 本次出场</span><span>随阅读展开</span></div><Control icon="book" onClick={() => { setCompanion(true); setBubble(null); }}>在伴读中展开</Control></> : <><p>如果你们抛下军队各自逃走，连一个亭长都能把你们抓住。</p><small>示例译注 · 鼠标可移入查看，也可固定</small></>}</aside>}
      </div>
      {modal === 'plan' && <Plan close={() => setModal(null)} selection={selection} setSelection={setSelection} paused={paused} setPaused={setPaused} setApplied={setApplied} notify={notify} saved={planOptions} save={setPlanOptions} />}
      {modal === 'tasks' && <Tasks close={() => setModal(null)} paused={paused} setPaused={setPaused} applied={applied} plan={() => { setPaused(true); setModal('plan'); }} />}
      {modal === 'settings' && <Dialog title="模型设置" icon="sparkle" close={() => setModal(null)} className="rn-models" footer={<><span className="rn-muted">本页仅演示样式，未连接服务</span><Control primary icon="check" onClick={() => { notify('示例设置已确认，没有保存密钥或调用模型。'); setModal(null); }}>完成</Control></>}><label>服务名称<input placeholder="自己的 AI" /></label><label>接口地址<input placeholder="https://…/v1" /></label><label>API Key<input type="password" placeholder="仅在本机保存" autoComplete="off" /></label><label>模型 ID<input placeholder="填写模型名称" /></label></Dialog>}
      {notice && <div className="rn-notice rn-surface" role="status">{notice}</div>}
    </div>
  </main>;
}
