import React, { useCallback, useEffect, useRef, useState } from 'react';
import { useApp, Icon, Button, Panel, Modal, Empty } from '../shared.jsx';
import './settings.css';
import './reader-next.css';

const PLUGINS = [
  { id: 'reader', name: '原文阅读', icon: 'reader', description: '保留原始 PDF 与文字，连接页码、批注和原文依据。', fixed: true, type: '内置插件' },
  { id: 'spatial', name: '时间与地图', icon: 'map', description: '用同一批事件连接时间、地点、参与者和原句。', component: 'spatial', route: 'map', type: '内置插件' },
  { id: 'mindmap', name: '思维导图', icon: 'mindmap', description: '每个节点引用真实笔记，保留连接与空间位置。', component: 'mindmap', route: 'mindmap', type: '内置插件' },
  { id: 'knowledge', name: '知识库', icon: 'knowledge', description: '连接本书的概念、文档、要素与可回查的出处。', component: 'knowledge', route: 'knowledge', type: '内置插件' },
  { id: 'workflow', name: '逐段精读', icon: 'workflow', description: '按页和段落执行方法，留下简短回执与待核对项。', route: 'workflow', type: '读书法' },
  { id: 'translation', name: '译注对照', icon: 'book', description: '在原文旁按需展开译文与注释，不覆盖原书。', route: 'reader', type: '声明式扩展' },
];

const COMPONENTS = [
  { id: 'spatial', name: '时间与地图', icon: 'map', plugin: 'spatial', route: 'map' },
  { id: 'mindmap', name: '思维导图', icon: 'mindmap', plugin: 'mindmap', route: 'mindmap' },
  { id: 'knowledge', name: '知识库', icon: 'knowledge', plugin: 'knowledge', route: 'knowledge' },
  { id: 'cards', name: '要素卡片', icon: 'cards', plugin: 'knowledge', route: 'cards' },
  { id: 'relations', name: '关系图谱', icon: 'relations', plugin: 'knowledge', route: 'relations' },
  { id: 'atlas', name: '全书总览', icon: 'atlas', plugin: 'knowledge', route: 'atlas' },
];

function useWindowWidth() {
  const [width, setWidth] = useState(() => window.innerWidth);
  useEffect(() => {
    const resize = () => setWidth(window.innerWidth);
    window.addEventListener('resize', resize);
    return () => window.removeEventListener('resize', resize);
  }, []);
  return width;
}

function Switch({ checked, onChange, label }) {
  return <button type="button" role="switch" aria-checked={checked} aria-label={label} onClick={onChange} className={`ps-switch ${checked ? 'is-on' : ''}`}><span /></button>;
}

// Page-local refinements keep the shared floating-panel interaction intact.
function SettingsPolishStyles() {
  return <style>{`
    .settings-page.sp-settings{font-size:15px;line-height:1.5}
    .settings-page.sp-settings .panel-header{height:56px;min-height:56px;padding:6px 8px 6px 16px}
    .settings-page.sp-settings .panel-header h2{font-size:16px;line-height:1.4}
    .settings-page.sp-settings .panel-header .button{min-width:44px;min-height:44px}
    .settings-page.sp-settings .panel-body{padding:16px;overscroll-behavior:contain}
    .settings-page.sp-settings .panel-footer{padding:12px 16px}
    .settings-page.sp-settings .button{min-height:44px;font-size:15px}
    .sp-main-header{display:flex;align-items:center;gap:10px;height:56px;min-height:56px;padding:6px 8px 6px 16px;border-bottom:1px solid var(--line);flex-shrink:0}
    .sp-main-header>svg{color:var(--accent)}.sp-main-header h1{font-size:16px;font-weight:600;margin:0;flex:1;min-width:0}
    .settings-page.sp-settings .ps-workspace{inset:88px 20px 20px;transition:none}
    .settings-page.sp-settings .ps-list-heading{padding:16px;gap:12px}
    .settings-page.sp-settings .ps-search{min-height:44px}.settings-page.sp-settings .ps-search button{width:44px;height:44px}
    .settings-page.sp-settings .ps-list-scroll{padding:0 16px;overscroll-behavior:contain}
    .settings-page.sp-settings .ps-plugin-row{min-height:96px;gap:16px;padding:16px 0}
    .settings-page.sp-settings .ps-icon-tile{width:48px;height:52px;border-radius:13px}
    .settings-page.sp-settings .ps-plugin-copy h2{font-size:16px}.settings-page.sp-settings .ps-plugin-copy p{font-size:15px}
    .settings-page.sp-settings .ps-panel-note{padding:8px 16px;min-height:60px;gap:8px}
    .settings-page.sp-settings .ps-type-form{padding:0;gap:16px}
    .settings-page.sp-settings .ps-type-suggestion{margin:0}.settings-page.sp-settings .ps-type-suggestion .button{height:44px!important;min-height:44px!important;font-size:15px}
    .settings-page.sp-settings .ps-helper,.settings-page.sp-settings .ps-caption{font-size:13px!important}
    .sp-footer-actions{display:flex;align-items:center;gap:10px;flex-wrap:wrap}.sp-footer-actions .sp-push{margin-left:auto}
    .settings-page.sp-settings .sp-model-config:not(.is-collapsed){height:var(--panel-available-height);max-height:var(--panel-available-height)!important}
    .settings-page.sp-settings .sp-model-config>.panel-body{padding:0;display:flex;flex:1;min-height:0;overflow:hidden}
    .sp-model-layout{display:flex;flex:1;min-height:0;min-width:0;width:100%}
    .sp-service-list{width:260px;flex-shrink:0;padding:16px 12px;border-right:1px solid var(--line);overflow:auto;overscroll-behavior:contain}
    .sp-service-list h3{font-size:15px;margin:0 4px 12px}.sp-service-list .ps-profile-row{min-height:64px;gap:12px;padding:10px 12px}
    .sp-service-list .ps-profile-row>span{font-size:15px}.sp-service-list .ps-profile-row small{font-size:12px}
    .sp-form-scroll{flex:1;min-width:0;min-height:0;overflow:auto;overscroll-behavior:contain;padding:16px}
    .settings-page.sp-settings .ps-model-form{padding:0;gap:16px}
    .settings-page.sp-settings .ps-model-form .ps-form-line{grid-template-columns:114px minmax(0,1fr);gap:16px;font-size:15px}
    .settings-page.sp-settings .ps-model-form input,.settings-page.sp-settings .ps-model-form select{font-size:15px}
    .settings-page.sp-settings .ps-model-form h3{font-size:16px}
    .sp-service-select{display:flex;align-items:center;gap:12px}.sp-service-select>span{font-size:15px;flex-shrink:0}.sp-service-select select{min-width:0;margin:0!important}
    .sp-settings-state{display:flex;gap:8px;align-items:center;flex-wrap:wrap}.sp-settings-state small{font-size:13px;color:var(--muted)}
    .settings-page.sp-settings .ps-test-options{gap:12px}.settings-page.sp-settings .ps-test-options>label{margin:0;min-height:44px}
    .settings-page.sp-settings .ps-test-options select{min-height:44px}
    @media(max-width:760px){.settings-page.sp-settings .ps-model-form .ps-form-line{display:flex;flex-direction:column;gap:6px}.settings-page.sp-settings .ps-form-line>span{padding-top:0}.settings-page.sp-settings .ps-form-line>div{width:100%}.settings-page.sp-settings .ps-list-heading{flex-wrap:wrap}.settings-page.sp-settings .ps-panel-note>span{display:none}}
  `}</style>;
}

export function PluginsPage() {
  const { state, update, navigate, notify, registerGuard, book } = useApp();
  const width = useWindowWidth();
  const [query, setQuery] = useState('');
  const [tab, setTab] = useState('installed');
  const [typesOpen, setTypesOpen] = useState(false);
  const [typesVisible, setTypesVisible] = useState(false);
  const [selectedType, setSelectedType] = useState('');
  const [typeName, setTypeName] = useState('');
  const [typeFields, setTypeFields] = useState('');
  const [typeError, setTypeError] = useState('');
  const [typeBaseline, setTypeBaseline] = useState('');
  const [typePending, setTypePending] = useState(null);
  const typeDirtyRef = useRef(false);
  const typePendingRef = useRef(null);
  const typeDraftRef = useRef(null);
  const saveTypeRef = useRef(null);
  const typeErrorRef = useRef(null);
  const [importOpen, setImportOpen] = useState(false);
  const [importError, setImportError] = useState('');
  const [packageText, setPackageText] = useState(JSON.stringify({ id: 'translation', name: '译注对照', version: '1.0', capabilities: ['reading.layers'] }, null, 2));
  const types = (state.typeDefinitions || []).filter(t => t.bookId === book.id);
  const enabled = state.enabledPlugins || [];
  const added = state.addedComponents || [];
  const available = COMPONENTS.filter(c => !added.includes(c.id));
  const typeDirty = JSON.stringify([selectedType, typeName, typeFields]) !== typeBaseline;
  typeDirtyRef.current = typeDirty;
  typePendingRef.current = typePending;
  typeDraftRef.current = { selectedType, typeName, typeFields, types, bookID: book.id };

  useEffect(() => {
    const type = types.find(t => t.id === selectedType) || types[0];
    setSelectedType(type?.id || 'new');
    setTypeName(type?.name || '');
    setTypeFields(type?.fields?.join('、') || '');
    setTypeBaseline(JSON.stringify([type?.id || 'new', type?.name || '', type?.fields?.join('、') || '']));
    typeDirtyRef.current = false;
    setTypeError('');
  }, [book.id]);

  useEffect(() => registerGuard?.(() => requestTypeChange()), [registerGuard]);
  useEffect(() => () => { typePendingRef.current?.resolve?.(false); }, []);
  useEffect(() => { if (typeError) typeErrorRef.current?.scrollIntoView({ block: 'nearest' }); }, [typeError]);

  function requestTypeChange(action) {
    if (!typeDirtyRef.current) { action?.(); return Promise.resolve(true); }
    if (typePendingRef.current) return Promise.resolve(false);
    return new Promise(resolve => {
      const next = { action, resolve };
      typePendingRef.current = next; setTypePending(next);
    });
  }
  function resolveTypeChange(choice) {
    const next = typePendingRef.current;
    if (choice === 'save' && !saveTypeRef.current()) return;
    if (choice === 'cancel') { next?.resolve(false); typePendingRef.current = null; setTypePending(null); return; }
    if (choice === 'discard') selectType(typeDraftRef.current.selectedType);
    typeDirtyRef.current = false;
    typePendingRef.current = null; setTypePending(null);
    next?.action?.(); next?.resolve(true);
  }
  function closeTypes() {
    if (!typeDirtyRef.current) return true;
    requestTypeChange(() => window.dispatchEvent(new CustomEvent('prototype-panel-close', { detail: { id: 'plugin-types' } })));
    return false;
  }

  useEffect(() => {
    const primary = () => { setImportError(''); setImportOpen(true); };
    window.addEventListener('prototype-primary', primary);
    return () => window.removeEventListener('prototype-primary', primary);
  }, []);

  function selectType(id) {
    const type = types.find(t => t.id === id);
    setSelectedType(id);
    setTypeName(type?.name || '');
    setTypeFields(type?.fields?.join('、') || '');
    setTypeBaseline(JSON.stringify([id, type?.name || '', type?.fields?.join('、') || '']));
    typeDirtyRef.current = false;
    setTypeError('');
  }

  function suggestType() {
    setSelectedType('new');
    setTypeName(book.kind === 'math' || book.id === 'math' ? '证明步骤' : '战役');
    setTypeFields(book.id === 'math' ? '前提、变换、结论、原文出处' : '时间、地点、参与者、结果、原文出处');
    setTypeError('');
    notify('已填入示例 AI 建议，可修改后保存；没有调用模型。');
  }

  function saveType() {
    const current = typeDraftRef.current;
    const name = current.typeName.trim();
    const fields = [...new Set(current.typeFields.split(/[、,，\n]/).map(s => s.trim()).filter(Boolean))];
    if (!name || !fields.length) { setTypeError('请填写类型名称和至少一个字段。'); return false; }
    if (current.types.some(t => t.name === name && t.id !== current.selectedType)) { setTypeError('本书已经有这个类型，请选择现有类型编辑。'); return false; }
    const id = current.selectedType === 'new' ? `type-${Date.now()}` : current.selectedType;
    update(prev => ({ ...prev, typeDefinitions: [...(prev.typeDefinitions || []).filter(t => t.id !== id), { id, bookId: current.bookID, name, fields, origin: current.selectedType === 'new' ? '自定义' : current.types.find(t => t.id === id)?.origin || '自定义' }] }));
    setSelectedType(id);
    setTypeName(name); setTypeFields(fields.join('、'));
    setTypeBaseline(JSON.stringify([id, name, fields.join('、')])); typeDirtyRef.current = false;
    setTypeError('');
    notify(`已保存“${name}”示例类型，精读流程会使用本书类型。`);
    return true;
  }
  saveTypeRef.current = saveType;

  function togglePlugin(plugin) {
    update(prev => ({ ...prev, enabledPlugins: (prev.enabledPlugins || []).includes(plugin.id) ? prev.enabledPlugins.filter(id => id !== plugin.id) : [...(prev.enabledPlugins || []), plugin.id] }));
    notify(enabled.includes(plugin.id) ? `已停用${plugin.name}，已有内容和组件配置保留。` : `已启用${plugin.name}。`);
  }

  function addComponent(component) {
    if (!enabled.includes(component.plugin)) { notify('请先启用所属插件；已有内容一直保留。'); return; }
    update(prev => ({ ...prev, addedComponents: [...new Set([...(prev.addedComponents || []), component.id])] }));
    notify(`已添加${component.name}；添加列表中不再重复显示。`);
  }

  function importPackage() {
    try {
      const definition = JSON.parse(packageText);
      if (!definition.id || !definition.name || !Array.isArray(definition.capabilities)) throw new Error('需要 id、name 与 capabilities 数组。');
      if (definition.id !== 'translation') throw new Error('此交互稿仅导入示例“译注对照”声明包，不执行外部代码。');
      update(prev => ({ ...prev, enabledPlugins: [...new Set([...(prev.enabledPlugins || []), 'translation'])] }));
      setImportOpen(false);
      notify('示例声明包已导入并启用；没有安装或执行外部代码。');
    } catch (error) { setImportError(`未导入：${error.message}`); }
  }

  const visiblePlugins = PLUGINS.filter(p => p.name.includes(query) || p.description.includes(query));
  const visibleComponents = available.filter(c => c.name.includes(query));

  return <section className="settings-page ps-plugins sp-settings" aria-label="插件与组件交互稿">
    <SettingsPolishStyles />
    <div className="ps-workspace" >
      <div className="ps-main-surface glass">
        <header className="sp-main-header"><Icon name="plugins" size={20} /><h1>插件与组件</h1><Button icon="close" variant="quiet" aria-label="关闭插件与组件" onClick={() => navigate(state.route)} /></header>
        <div className="ps-list-heading">
          <label className="ps-search"><Icon name="search" /><input value={query} onChange={e => setQuery(e.target.value)} placeholder="搜索插件或组件…" aria-label="搜索插件或组件" />{query && <button onClick={() => setQuery('')} aria-label="清空插件搜索"><Icon name="close" size={16} /></button>}</label>
          <div className="ps-segments" aria-label="插件显示范围"><button className={tab === 'installed' ? 'is-active' : ''} onClick={() => setTab('installed')}>插件</button><button className={tab === 'addable' ? 'is-active' : ''} onClick={() => setTab('addable')}>可添加 <span>{available.length}</span></button></div>
        </div>
        <div className="ps-list-scroll">
          {tab === 'installed' ? visiblePlugins.length ? visiblePlugins.map(plugin => <article key={plugin.id} className="ps-plugin-row">
            <div className={`ps-icon-tile ${enabled.includes(plugin.id) || plugin.fixed ? '' : 'is-muted'}`}><Icon name={plugin.icon} size={32} /></div>
            <div className="ps-plugin-copy"><h2>{plugin.name}</h2><p>{plugin.description}</p>{plugin.component && <div className="ps-inline-status">{!enabled.includes(plugin.id) ? '已停用 · 内容保留' : added.includes(plugin.component) ? '本书已添加' : '已启用 · 尚未添加到本书'}</div>}</div>
            <span className="ps-badge">{plugin.type}</span>
            {plugin.fixed ? <span className="ps-fixed-tag">常驻</span> : <Switch checked={enabled.includes(plugin.id)} label={`${enabled.includes(plugin.id) ? '停用' : '启用'}${plugin.name}`} onChange={() => togglePlugin(plugin)} />}
          </article>) : <Empty icon="plugins" title="没有匹配的插件">换个名称，或清空搜索。</Empty> : visibleComponents.length ? visibleComponents.map(component => <article key={component.id} className="ps-plugin-row ps-component-row"><div className="ps-icon-tile"><Icon name={component.icon} size={30} /></div><div className="ps-plugin-copy"><h2>{component.name}</h2><p>{enabled.includes(component.plugin) ? '尚未添加到当前书；添加后出现在主导航。' : '所属插件已停用；请先回到插件页启用。'}</p></div><Button icon="plus" disabled={!enabled.includes(component.plugin)} onClick={() => addComponent(component)}>添加</Button></article>) : <Empty icon="check" title={query ? '没有匹配的可添加组件' : '本书组件已经齐全'}>{query ? '试试其他关键词。' : '已添加的项目不会再次出现在这里。'}</Empty>}
        </div>
        <div className="ps-panel-note"><details className="settings-advanced-menu"><summary><Icon name="settings"/>类型与阅读方法</summary><div className="glass settings-action-menu"><Button aria-label="编辑卡片类型" variant="quiet" onClick={event => { event.currentTarget.closest("details")?.removeAttribute("open"); setTypesOpen(true); setTypesVisible(true); window.dispatchEvent(new CustomEvent('prototype-panel-open', { detail: { id: 'plugin-types' } })); }} icon="cards">卡片类型</Button><Button aria-label="打开智能阅读方法" variant="quiet" onClick={() => navigate('workflow')} icon="workflow">阅读方法</Button></div></details><Button icon="upload" variant="primary" onClick={() => { setImportError(''); setImportOpen(true); }}>导入 / 升级</Button></div>
      </div>
    </div>
    {typesOpen && <Panel stationary singleDismiss id="plugin-types" title="本书卡片类型" width={360} dock="right" initial={{ x: Math.max(20, width - 380), y: 88 }} onVisibilityChange={setTypesVisible} onRequestClose={closeTypes}
      footer={<div className="sp-footer-actions"><Button className="sp-push" variant="primary" icon="save" onClick={saveType}>保存类型</Button></div>}>
      <div className="ps-type-form">
        <div className="sp-settings-state"><small>{book.title}</small><small>{typeDirty ? '有未保存修改' : selectedType === 'new' ? '新建定义' : '已保存定义'}</small></div>
        <label>选择类型<select value={selectedType} onChange={e => { const id = e.target.value; requestTypeChange(() => selectType(id)); }}>{types.map(type => <option key={type.id} value={type.id}>{type.name}</option>)}<option value="new">＋ 新建类型</option></select></label>
        <div className="ps-type-suggestion"><Button variant="quiet" icon="sparkle" onClick={() => requestTypeChange(suggestType)}>AI 建议 · 演示</Button></div>
        <div className="ps-form-rule" />
        <label>名称<input value={typeName} onChange={e => setTypeName(e.target.value)} placeholder="由书决定，例如定理、战役" /></label>
        <p className="ps-helper">按书定义，不限定为人物卡片。</p>
        <label>字段<textarea value={typeFields} onChange={e => setTypeFields(e.target.value)} placeholder="用顿号或换行分隔" rows={5} /></label>
        {typeError && <p ref={typeErrorRef} className="ps-error" role="alert">{typeError}</p>}
        <p className="ps-caption">只保存本地示例；折叠、缩窗保留输入，不调用真实 AI。</p>
      </div>
    </Panel>}
    {typePending && <Modal title="这份定义还没有保存" onClose={() => resolveTypeChange('cancel')} footer={<><Button onClick={() => resolveTypeChange('cancel')}>继续编辑</Button><Button onClick={() => resolveTypeChange('discard')}>放弃并继续</Button><Button variant="primary" onClick={() => resolveTypeChange('save')}>保存并继续</Button></>}><p>先处理名称与字段的修改，再切换定义或离开。保存失败会保留全部输入。</p>{typeError && <p className="ps-error" role="alert">{typeError}</p>}</Modal>}
    {importOpen && <Modal title="导入声明式插件 · 演示" onClose={() => setImportOpen(false)} footer={<><Button onClick={() => setImportOpen(false)}>取消</Button><Button variant="primary" icon="upload" onClick={importPackage}>导入示例</Button></>}><div className="ps-modal-body"><p>查看声明包如何提供类型、读书法和组件。交互稿仅接收下方示例，不执行代码。</p><label>插件声明<textarea className="ps-code" value={packageText} onChange={e => setPackageText(e.target.value)} rows={9} spellCheck={false} /></label>{importError && <p className="ps-error" role="alert">{importError}</p>}</div></Modal>}
  </section>;
}

const PROVIDER_PRESETS = [
  { provider: 'deepseek', name: 'DeepSeek', baseURL: 'https://api.deepseek.com/v1/chat/completions', modelId: 'deepseek-flash', maxOutputTokens: 393216, vision: true },
  { provider: 'qwen', name: '通义千问', baseURL: 'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions', modelId: 'qwen3.8-flash', maxOutputTokens: 131072, vision: true },
  { provider: 'moonshot', name: 'Kimi', baseURL: 'https://api.moonshot.cn/v1/chat/completions', modelId: 'kimi-k3', maxOutputTokens: 1048576, vision: true },
  { provider: 'zhipu', name: '智谱 GLM', baseURL: 'https://open.bigmodel.cn/api/paas/v4/chat/completions', modelId: 'glm-5.3', maxOutputTokens: 131072, vision: false },
  { provider: 'doubao', name: '豆包', baseURL: 'https://ark.cn-beijing.volces.com/api/v3/chat/completions', modelId: 'doubao-seed-2-1-pro-260915', maxOutputTokens: null, vision: true },
  { provider: 'openai', name: 'OpenAI', baseURL: 'https://api.openai.com/v1/chat/completions', modelId: 'gpt-5.4-mini-2026-03-17', maxOutputTokens: 128000, vision: true },
  { provider: 'anthropic', name: 'Claude', baseURL: 'https://api.anthropic.com/v1/chat/completions', modelId: 'claude-sonnet-5-5', maxOutputTokens: null, vision: true },
  { provider: 'custom', name: '自定义兼容服务', baseURL: '', modelId: '', maxOutputTokens: null, vision: false },
];

function profileDraft(profile) {
  return { id: profile?.id || '', name: profile?.name || '', provider: profile?.provider || 'custom', baseURL: profile?.baseURL || '', modelId: profile?.modelId || '', maxTokens: profile?.maxTokens || 8192, maxOutputTokens: profile?.maxOutputTokens || null, vision: !!profile?.vision, contextTokens: profile?.contextTokens || '', tokenParameter: profile?.tokenParameter || 'max_tokens', requests: profile?.requests || 30, example: true };
}

function draftWithModelId(current, modelId, knownLimits) {
  const key = `${current.provider}:${modelId.trim()}`;
  return { ...current, modelId, maxOutputTokens: knownLimits.get(key) || null };
}

export function ModelsPage() {
  const app = useApp();
  const { state, update, notify, confirm } = app;
  const width = useWindowWidth();
  const initialProfile = state.profiles?.find(p => p.id === state.activeProfileId) || state.profiles?.[0];
  const [selectedId, setSelectedId] = useState(initialProfile?.id || '');
  const [draft, setDraft] = useState(() => profileDraft(initialProfile));
  const [saved, setSaved] = useState(() => JSON.stringify(profileDraft(initialProfile)));
  const [error, setError] = useState('');
  const [testState, setTestState] = useState('idle');
  const [testOutcome, setTestOutcome] = useState('success');
  const [advanced, setAdvanced] = useState(false);
  const [newOpen, setNewOpen] = useState(false);
  const [pending, setPending] = useState(null);
  const testTimer = useRef(null);
  const errorRef = useRef(null);
  const knownLimits = useRef(null);
  if (!knownLimits.current) {
    knownLimits.current = new Map();
    for (const model of [...PROVIDER_PRESETS, ...(state.profiles || [])]) {
      if (Number(model.maxOutputTokens) > 0) knownLimits.current.set(`${model.provider}:${model.modelId.trim()}`, Number(model.maxOutputTokens));
    }
  }
  const dirty = JSON.stringify(draft) !== saved;
  const draftRef = useRef(draft);
  const dirtyRef = useRef(dirty);
  const pendingRef = useRef(null);
  draftRef.current = draft;
  dirtyRef.current = dirty;
  pendingRef.current = pending;

  useEffect(() => () => { clearTimeout(testTimer.current); pendingRef.current?.resolve?.(false); }, []);
  useEffect(() => { if (error) errorRef.current?.scrollIntoView({ block: 'nearest' }); }, [error]);
  useEffect(() => {
    for (const profile of state.profiles || []) {
      if (Number(profile.maxOutputTokens) > 0) knownLimits.current.set(`${profile.provider}:${profile.modelId.trim()}`, Number(profile.maxOutputTokens));
    }
  }, [state.profiles]);

  const save = useCallback(() => {
    const current = draftRef.current;
    if (!current.name.trim() || !current.modelId.trim() || !current.baseURL.trim()) { setError('请填写服务名称、接口地址和模型 ID。'); return false; }
    try { const parsed = new URL(current.baseURL); if (!['https:', 'http:'].includes(parsed.protocol)) throw new Error(); } catch { setError('接口地址应为完整的 http 或 https 地址。'); return false; }
    const output = Number(current.maxTokens);
    if (!Number.isInteger(output) || output < 1 || (current.maxOutputTokens && output > Number(current.maxOutputTokens))) { setError(current.maxOutputTokens ? `输出 Token 必须为 1–${Number(current.maxOutputTokens).toLocaleString()} 的整数。` : '输出 Token 必须为正整数；未知规格请手动核查。'); return false; }
    if (current.contextTokens && (!Number.isInteger(Number(current.contextTokens)) || Number(current.contextTokens) < output)) { setError('上下文 Token 应为不小于输出 Token 的整数，未知时可以留空。'); return false; }
    const next = { ...current, id: current.id || `profile-${Date.now()}`, name: current.name.trim(), baseURL: current.baseURL.trim(), modelId: current.modelId.trim(), maxTokens: output, status: 'saved', example: true };
    update(prev => ({ ...prev, profiles: [...(prev.profiles || []).filter(p => p.id !== next.id), next], activeProfileId: next.id }));
    const normalized = profileDraft(next);
    setDraft(normalized);
    draftRef.current = normalized;
    setSaved(JSON.stringify(normalized));
    dirtyRef.current = false;
    setSelectedId(next.id);
    setError('');
    notify('示例配置已保存到本次交互稿，不含密钥。');
    return true;
  }, [notify, update]);

  useEffect(() => {
    if (!app.registerGuard) return undefined;
    return app.registerGuard(() => {
      if (!dirtyRef.current) return true;
      return new Promise(resolve => setPending({ kind: 'leave', resolve }));
    });
  }, [app.registerGuard]);

  useEffect(() => {
    const primary = () => save();
    window.addEventListener('prototype-primary', primary);
    return () => window.removeEventListener('prototype-primary', primary);
  }, [save]);

  function loadProfile(profile) {
    const next = profileDraft(profile);
    setSelectedId(profile?.id || '');
    setDraft(next);
    draftRef.current = next; dirtyRef.current = false;
    setSaved(JSON.stringify(next));
    setError('');
    setTestState('idle');
    clearTimeout(testTimer.current);
    if (profile?.id) update(prev => ({ ...prev, activeProfileId: profile.id }));
  }

  function requestLoad(profile) {
    if (profile?.id === selectedId) return;
    if (dirty) setPending({ kind: 'load', profile });
    else loadProfile(profile);
  }

  function resolvePending(choice) {
    const next = pending;
    if (choice === 'save' && !save()) return;
    if (choice === 'cancel') { next?.resolve?.(false); setPending(null); return; }
    if (choice === 'discard') {
      const original = profileDraft((state.profiles || []).find(profile => profile.id === selectedId));
      setDraft(original); draftRef.current = original; setSaved(JSON.stringify(original)); dirtyRef.current = false; setError('');
    }
    setPending(null);
    if (next?.kind === 'leave') { dirtyRef.current = false; next.resolve(true); }
    else if (next?.kind === 'load') loadProfile(next.profile);
    else if (next?.kind === 'new') { setNewOpen(true); }
  }

  function newFromPreset(preset) {
    loadProfile({ ...preset, id: '', name: preset.name, maxTokens: 8192 });
    setNewOpen(false);
    // A new draft still needs an explicit save, even before its first edit.
    setSaved('new-unsaved-profile');
  }

  function applyPreset(provider) {
    const preset = PROVIDER_PRESETS.find(p => p.provider === provider);
    if (!preset) return;
    setDraft(current => ({ ...current, ...preset, name: current.name || preset.name, maxTokens: Math.min(Number(current.maxTokens) || 8192, preset.maxOutputTokens || 8192) }));
    setTestState('idle');
    setError('');
  }

  async function deleteProfile() {
    if (!selectedId) return;
    if (!await confirm({ title: '删除这个示例配置？', body: `${dirty ? '当前未保存的配置修改也会放弃。' : ''}只删除本次交互稿中的服务配置。书籍、笔记和分析内容保留；这里没有真实密钥。`, confirmLabel: '删除配置', danger: true })) return;
    const remaining = (state.profiles || []).filter(p => p.id !== selectedId);
    update(prev => ({ ...prev, profiles: (prev.profiles || []).filter(p => p.id !== selectedId), activeProfileId: remaining[0]?.id || '' }));
    loadProfile(remaining[0]);
    notify('示例服务配置已删除，内容保留。');
  }

  function testConfig() {
    if (!draft.name.trim() || !draft.modelId.trim() || !draft.baseURL.trim()) { setError('请先补齐连接字段，再演示测试结果。'); return; }
    try { const url = new URL(draft.baseURL); if (!['http:', 'https:'].includes(url.protocol)) throw new Error(); } catch { setError('请先填写有效的 http 或 https 接口地址。'); return; }
    if (!Number.isInteger(Number(draft.maxTokens)) || Number(draft.maxTokens) < 1 || (draft.maxOutputTokens && Number(draft.maxTokens) > Number(draft.maxOutputTokens))) { setError('请先修正输出 Token，再演示测试结果。'); return; }
    clearTimeout(testTimer.current);
    setError('');
    setTestState('testing');
    testTimer.current = setTimeout(() => { setTestState(testOutcome); notify(testOutcome === 'success' ? '演示连接成功；没有发起网络请求。' : '演示连接失败；输入和未保存修改已保留。'); }, 900);
  }

  const setField = (field, value) => { clearTimeout(testTimer.current); setDraft(current => ({ ...current, [field]: value })); setError(''); if (testState !== 'idle') setTestState('idle'); };
  const profileWidth = Math.max(240, Math.min(860, width - 40));
  const showServiceList = width >= 1000;
  const requestNew = () => dirty ? setPending({ kind: 'new' }) : setNewOpen(true);
  const closeSettings = () => app.navigate(state.route);

  return <section className="settings-page ps-models sp-settings" aria-label="模型设置交互稿">
    <SettingsPolishStyles />
    <Panel stationary singleDismiss maximumHeight={680} id="model-config" title="模型设置" className="ps-model-config sp-model-config" width={profileWidth} dock="right" initial={{ x: Math.max(20, (width - profileWidth) / 2), y: 88 }}
      actions={<Button icon="plus" variant="quiet" aria-label="新建服务" title="新建服务" onClick={requestNew}/>}
      onRequestClose={() => { closeSettings(); return false; }}
      footer={<div className="sp-footer-actions"><Button icon="play" disabled={testState === 'testing'} onClick={testConfig}>{testState === 'testing' ? '测试中…' : '测试连接 · 演示'}</Button><Button icon="trash" variant="quiet" disabled={!selectedId} onClick={deleteProfile} aria-label="删除当前示例配置" /><Button className="sp-push" icon="save" variant="primary" onClick={save}>保存配置</Button></div>}>
      <div className="sp-model-layout">
      {showServiceList && <aside className="sp-service-list" aria-label="我的服务"><h3>我的服务 · {state.profiles?.length || 0}</h3><div className="ps-profile-list">{(state.profiles || []).map(profile => <button className={`ps-profile-row ${selectedId === profile.id ? 'is-selected' : ''}`} key={profile.id} onClick={() => requestLoad(profile)}><Icon name="link" size={22} /><span>{profile.name}</span>{state.activeProfileId === profile.id && <small>当前</small>}</button>)}{!state.profiles?.length && <p className="ps-helper">还没有保存的服务，可从上方新建。</p>}</div></aside>}
      <div className="sp-form-scroll">
      <div className="ps-model-form">
        {!showServiceList && <label className="sp-service-select"><span>我的服务</span><select value={selectedId} onChange={e => requestLoad((state.profiles || []).find(profile => profile.id === e.target.value))}>{!selectedId && <option value="">新的未保存配置</option>}{(state.profiles || []).map(profile => <option key={profile.id} value={profile.id}>{profile.name}</option>)}</select></label>}
        <div role="status" className={`ps-save-state ${dirty ? 'is-dirty' : ''}`}><i />{dirty ? '未保存的更改' : '已保存'} · 示例配置</div>
        <label className="ps-form-line"><span>服务名称</span><input value={draft.name} onChange={e => setField('name', e.target.value)} placeholder="给这份配置命名" /></label>
        <label className="ps-form-line"><span>接口地址</span><input value={draft.baseURL} onChange={e => setField('baseURL', e.target.value)} placeholder="https://…/chat/completions" spellCheck={false} /></label>
        <label className="ps-form-line"><span>API Key</span><div><input type="password" readOnly value="PROTOTYPE-EXAMPLE-ONLY" autoComplete="off" aria-describedby="ps-key-note" /><small id="ps-key-note">只读示例，请勿输入真实密钥。没有保存密钥。</small></div></label>
        <label className="ps-form-line"><span>模型 ID</span><div><input value={draft.modelId} onChange={e => { const modelId = e.target.value; setField('modelId', modelId); setDraft(current => draftWithModelId(current, modelId, knownLimits.current)); }} spellCheck={false} /><small>已知型号恢复示例上限；未知型号的 Max 不可用。</small></div></label>
        <div className="ps-form-rule" />
        <h3>输出设置</h3>
        <label className="ps-form-line"><span>最大输出 Token</span><div><div className="ps-token-controls"><input type="number" min="1" value={draft.maxTokens} onChange={e => setField('maxTokens', e.target.value)} /><Button disabled={!draft.maxOutputTokens} onClick={() => { setField('maxTokens', draft.maxOutputTokens); notify(`已填入示例输出上限 ${Number(draft.maxOutputTokens).toLocaleString()} Token。`); }}>Max</Button></div><small>{draft.maxOutputTokens ? `示例已知上限 ${Number(draft.maxOutputTokens).toLocaleString()}。Max 只设置输出额度。` : '此型号上限未知，Max 已禁用。'}</small></div></label>
        <label className="ps-form-line"><span>视觉识别</span><div className="ps-vision-row"><select value={draft.vision ? 'yes' : 'no'} onChange={e => setField('vision', e.target.value === 'yes')}><option value="yes">支持 · 示例能力</option><option value="no">不支持 / 未声明</option></select><small>尚未实际检测</small></div></label>
        <div className="ps-form-rule" />
        <button className="ps-disclosure" aria-expanded={advanced} onClick={() => setAdvanced(!advanced)}><Icon name={advanced ? 'chevronDown' : 'chevronRight'} size={18} />高级设置</button>
        {advanced && <div className="ps-advanced"><label className="ps-form-line"><span>提供商预设</span><select value={draft.provider} onChange={e => applyPreset(e.target.value)}>{PROVIDER_PRESETS.map(preset => <option key={preset.provider} value={preset.provider}>{preset.name}</option>)}</select></label><label className="ps-form-line"><span>上下文 Token</span><input type="number" min="1" placeholder="未知时留空" value={draft.contextTokens} onChange={e => setField('contextTokens', e.target.value)} /></label><label className="ps-form-line"><span>输出参数</span><select value={draft.tokenParameter} onChange={e => setField('tokenParameter', e.target.value)}><option value="max_tokens">max_tokens</option><option value="max_completion_tokens">max_completion_tokens</option></select></label><label className="ps-form-line"><span>每轮请求预算</span><input type="number" min="1" max="2000" value={draft.requests} onChange={e => setField('requests', Math.max(1, Math.min(2000, Number(e.target.value) || 1)))} /></label><p className="ps-caption">预设数值取自项目示例目录（2026-10-14），不是实时规格。真实使用前需核对官方模型文档。更高 Token 上限不保证理解正确。</p></div>}
        {error && <p ref={errorRef} className="ps-error" role="alert"><Icon name="warning" size={18} />{error}</p>}
        {testState !== 'idle' && <div className={`ps-test-result ${testState === 'error' ? 'is-error' : ''}`} role="status"><Icon name={testState === 'testing' ? 'refresh' : testState === 'success' ? 'check' : 'warning'} size={20} /><div><strong>{testState === 'testing' ? '正在演示测试…' : testState === 'success' ? '演示连接成功' : '演示连接失败'}</strong><p>{testState === 'error' ? '示例错误：模型 ID 未被服务接受。请检查输入后重试，草稿仍在。' : '仅演示界面状态，没有发起真实请求，也没有验证 OCR。'}</p></div></div>}
        <div className="ps-test-options"><Icon name="info" size={17} /><span>不发真实请求</span><label>演示结果<select value={testOutcome} onChange={e => setTestOutcome(e.target.value)}><option value="success">成功</option><option value="error">失败</option></select></label></div>
      </div>
      </div>
      </div>
    </Panel>
    {newOpen && <Modal title="新建服务 · 选择示例预设" onClose={() => setNewOpen(false)}><div className="ps-provider-grid">{PROVIDER_PRESETS.map(preset => <button key={preset.provider} onClick={() => newFromPreset(preset)}><Icon name="link" size={23} /><span>{preset.name}</span><Icon name="chevronRight" size={18} /></button>)}</div><p className="ps-modal-disclaimer">创建的是内存示例配置。密钥框保持只读。</p></Modal>}
    {pending && <Modal title="这份配置还没有保存" onClose={() => resolvePending('cancel')} footer={<><Button onClick={() => resolvePending('cancel')}>继续编辑</Button><Button onClick={() => resolvePending('discard')}>放弃并继续</Button><Button variant="primary" onClick={() => resolvePending('save')}>保存并继续</Button></>}><div className="ps-modal-body"><p>先处理当前草稿，再{pending.kind === 'leave' ? '离开设置' : pending.kind === 'new' ? '新建服务' : '切换服务'}。保存失败时会保留输入。</p>{error && <p className="ps-error" role="alert">{error}</p>}</div></Modal>}
  </section>;
}

const SEGMENTS = {
  math: [
    ['1', '1', '线性方程组的解可以通过等价的初等行变换研究。', '说明用等价行变换研究解。'],
    ['1', '2', '交换两行、某行乘非零常数、将一行的倍数加到另一行。', '列出三种初等行变换。'],
    ['1', '3', '把系数与常数项写在一起，得到增广矩阵。', '定义增广矩阵的组成。'],
    ['2', '1', '每一步变换都应当保留原线性方程组的解集。', '强调变换前后的解集一致。'],
    ['2', '2', '主元列的位置决定基本变量，其余变量作为自由变量。', '区分基本变量与自由变量。'],
    ['2', '3', '若出现左侧全零而右侧非零的一行，则方程组不相容。', '说明无解的判定条件。'],
    ['3', '1', '当秩等于未知数个数时，相容方程组有唯一解。', '给出相容且唯一解的条件。'],
    ['3', '2', '当秩小于未知数个数时，自由变量产生无穷多个解。', '说明自由变量与无穷多解。'],
  ],
  history: [
    ['1', '1', '建安十三年，曹操南下，荆州局势随之改变。', '交代事件年代与南下背景。'],
    ['1', '2', '刘备退往夏口，诸葛亮奉命出使江东。', '记录退往夏口与出使江东。'],
    ['1', '3', '孙权召集群臣，议论战与降的选择。', '提出江东内部的决策分歧。'],
    ['2', '1', '周瑜分析曹军远来与水战经验的不足。', '概括对敌军条件的判断。'],
    ['2', '2', '孙刘议定联合，共同抵御南下的曹军。', '记下联盟形成与共同目标。'],
    ['2', '3', '两军在赤壁相遇，战事与江面位置密切相关。', '将战事关联到赤壁与江面。'],
    ['3', '1', '黄盖提出火攻之计，须借助风向与船只接近。', '记录火攻方案及所需条件。'],
    ['3', '2', '战后的记述仍须区分小说叙事与史料证据。', '提醒区分叙事与证据来源。'],
  ],
};

function parseMethodSteps(value) {
  const text = Array.isArray(value) ? value.join('\n') : String(value || '');
  return text.split(/\r\n|\r|\n|\\r\\n|\\n|\\r/).map(step => step.trim()).filter(Boolean);
}

export function WorkflowPage() {
  const { state, update, navigate, notify, book } = useApp();
  const width = useWindowWidth();
  const workflow = state.workflow?.bookId && state.workflow.bookId !== book.id ? {status:'idle',receipts:[],pluginLog:[],methodId:book.id==='math'?'proof':'close',cursor:0} : state.workflow || { status: 'idle', receipts: [], pluginLog: [], methodId: 'close', cursor: 0 };
  const methods = state.readingMethods || [];
  const [methodOpen, setMethodOpen] = useState(false);
  const [methodVisible, setMethodVisible] = useState(false);
  const [editingMethodId, setEditingMethodId] = useState(workflow.methodId || methods[0]?.id || 'close');
  const [methodName, setMethodName] = useState('');
  const [methodDescription, setMethodDescription] = useState('');
  const [methodSteps, setMethodSteps] = useState('');
  const [methodError, setMethodError] = useState('');
  const [simulateFailure, setSimulateFailure] = useState(false);
  const [expandedReceipt, setExpandedReceipt] = useState('');
  const [showLog, setShowLog] = useState(false);
  const [processingOpen, setProcessingOpen] = useState(false);
  const [customType, setCustomType] = useState('');
  const [planReady, setPlanReady] = useState(!!workflow.planReady);
  const kind = book.id === 'math' ? 'math' : 'history';
  const bookTypes = state.bookProfiles?.[book.id]?.types || (kind === 'math' ? ['教材'] : ['历史','战争','小说']);
  const toggleBookType = type => update(prev => { const before = prev.bookProfiles?.[book.id]?.types || (kind === 'math' ? ['教材'] : ['历史','战争','小说']); return {...prev,bookProfiles:{...prev.bookProfiles,[book.id]:{types:before.includes(type)?before.filter(t=>t!==type):[...before,type]}}}; });
  const segments = SEGMENTS[kind];
  const receipts = workflow.bookId === book.id || !workflow.bookId ? workflow.receipts || [] : [];
  const completed = receipts.filter(r => r.status === 'done').length;
  const currentMethod = methods.find(m => m.id === workflow.methodId) || methods[0];
  const running = workflow.status === 'running' && (!workflow.bookId || workflow.bookId === book.id);
  const activeTypeNames = (state.typeDefinitions || []).filter(t => t.bookId === book.id).map(t => t.name);
  const exitStateRef = useRef({ update, bookId: book.id });
  exitStateRef.current = { update, bookId: book.id };

  // Separate from the per-segment timer: only leaving this mounted page pauses it.
  useEffect(() => () => {
    const current = exitStateRef.current;
    current.update(prev => {
      const task = prev.workflow;
      if (task?.status !== 'running' || (task.bookId && task.bookId !== current.bookId)) return prev;
      return { ...prev, workflow: { ...task, status: 'paused' } };
    });
  }, []);

  useEffect(() => {
    if (editingMethodId === 'new') return;
    const method = methods.find(m => m.id === editingMethodId) || methods[0];
    setMethodName(method?.name || '');
    setMethodDescription(method?.description || '');
    setMethodSteps(parseMethodSteps(method?.steps).join('\n'));
    setMethodError('');
  }, [editingMethodId]);

  useEffect(() => {
    setPlanReady(!!state.workflow?.planReady && state.workflow?.bookId === book.id);
  }, [book.id]);

  useEffect(() => {
    if (!running) return undefined;
    const timer = setInterval(() => {
      update(prev => {
        const w = prev.workflow || {};
        if (w.status !== 'running' || w.bookId !== book.id) return prev;
        const index = w.cursor || 0;
        if (index >= segments.length) return { ...prev, workflow: { ...w, status: 'completed' } };
        const [page, paragraph, text, summary] = segments[index];
        const id = `${book.id}-p${page}-${paragraph}`;
        if (w.simulateFailure && !w.failureConsumed && index === 3) return { ...prev, workflow: { ...w, status: 'error', failureConsumed: true, error: '示例网络中断：第 2 页第 1 段未取得完整回执。', receipts: [...(w.receipts || []).filter(r => r.id !== id), { id, page: Number(page), paragraph: Number(paragraph), text, summary: '', status: 'failed' }] } };
        const nextReceipts = [...(w.receipts || []).filter(r => r.id !== id), { id, page: Number(page), paragraph: Number(paragraph), text, summary, status: 'done', method: w.methodId }];
        const done = index + 1 === segments.length;
        const enabled = prev.enabledPlugins || [];
        const typeNames = (prev.typeDefinitions || []).filter(t => t.bookId === book.id).map(t => t.name);
        const method = (prev.readingMethods || []).find(m => m.id === w.methodId);
        const pluginLog = done ? [
          { id: 'coverage', plugin: '原文阅读', action: `核对 ${segments.length} 个段落 ID 与页码；保留 3 页原文。` },
          { id: 'method', plugin: '阅读方法', action: `执行“${method?.name || '逐段精读'}”：${method?.steps?.join(' → ') || '概括 → 提问 → 核对'}。` },
          { id: 'types', plugin: '要素类型', action: `选择本书类型：${typeNames.join('、') || '未定义类型，先保留原文回执'}。` },
          ...enabled.includes('knowledge') ? [{ id: 'knowledge', plugin: '知识库', action: '模拟创建要素并关联原文依据；不写入用户笔记。' }] : [],
          ...kind === 'history' && enabled.includes('spatial') ? [{ id: 'spatial', plugin: '时间与地图', action: '模拟把同一事件 ID、人物 ID 与地点 ID 交给地图和时间轴。' }] : [],
          ...enabled.includes('mindmap') ? [{ id: 'mindmap', plugin: '思维导图', action: '保留用户文档节点；AI 分析不覆盖文档正文。' }] : [],
        ] : w.pluginLog || [];
        return { ...prev, workflow: { ...w, cursor: index + 1, receipts: nextReceipts, status: done ? 'completed' : 'running', pluginLog, error: '' } };
      });
    }, 900);
    return () => clearInterval(timer);
  }, [running, book.id, kind, segments, update]);

  function makePlan() {
    if (running) return;
    const suggested = methods.find(m => m.id === (kind === 'math' ? 'proof' : 'close')) || methods[0];
    update(prev => ({ ...prev, workflow: { ...prev.workflow, bookId: book.id, methodId: suggested?.id || 'close', planReady: true, status: 'idle', receipts: [], pluginLog: [], cursor: 0, failureConsumed: false } }));
    setEditingMethodId(suggested?.id || 'close');
    setPlanReady(true);
    notify(`预读演示完成：${kind === 'math' ? '证明与概念较多' : '叙事、地点与时间较多'}，建议“${suggested?.name || '逐段精读'}”。可以改选或自定义。`);
  }

  function startOrResume() {
    if (!planReady) { makePlan(); return; }
    if (!(state.enabledPlugins || []).includes('workflow')) { notify('请先在插件页启用逐段精读。'); return; }
    update(prev => ({ ...prev, workflow: { ...prev.workflow, bookId: book.id, planReady: true, status: 'running', simulateFailure, ...(prev.workflow?.status === 'completed' || prev.workflow?.bookId !== book.id ? { cursor: 0, receipts: [], pluginLog: [], failureConsumed: false } : {}) } }));
  }

  const actionRef = useRef(null);
  actionRef.current = () => running ? update(prev => ({ ...prev, workflow: { ...prev.workflow, status: 'paused' } })) : startOrResume();
  useEffect(() => {
    const primary = () => actionRef.current?.();
    const openMethod = () => { setMethodOpen(true); setMethodVisible(true); requestAnimationFrame(()=>window.dispatchEvent(new CustomEvent('prototype-panel-open',{detail:{id:'reading-method'}}))); };
    window.addEventListener('prototype-primary', primary);
    window.addEventListener('prototype-method-open', openMethod);
    return () => { window.removeEventListener('prototype-primary', primary); window.removeEventListener('prototype-method-open', openMethod); };
  }, []);

  function selectMethod(id) {
    if (running) { notify('先暂停精读，再更换方法。'); return; }
    if (id !== 'new') {
      update(prev => ({ ...prev, workflow: { ...prev.workflow, ...(prev.workflow?.bookId && prev.workflow.bookId !== book.id ? { receipts: [], cursor: 0, pluginLog: [], status: 'idle' } : {}), bookId: book.id, methodId: id, planReady: true } }));
      setPlanReady(true);
    }
    setEditingMethodId(id);
  }

  function saveMethod() {
    const steps = parseMethodSteps(methodSteps);
    if (!methodName.trim() || !steps.length) { setMethodError('请填写方法名称和至少一个执行步骤。'); return; }
    const id = editingMethodId === 'new' ? `method-${Date.now()}` : editingMethodId;
    const method = { id, name: methodName.trim(), description: methodDescription.trim(), steps };
    update(prev => ({ ...prev, readingMethods: [...(prev.readingMethods || []).filter(m => m.id !== id), method], workflow: { ...prev.workflow, ...(prev.workflow?.bookId && prev.workflow.bookId !== book.id ? { receipts: [], cursor: 0, pluginLog: [], status: 'idle' } : {}), bookId: book.id, methodId: id, planReady: true } }));
    setEditingMethodId(id);
    setMethodSteps(steps.join('\n'));
    setPlanReady(true);
    setMethodError('');
    notify(`已保存“${method.name}”；模拟执行记录会显示这套步骤。`);
  }

  function suggestMethod() {
    if (running) return;
    setEditingMethodId('new');
    setMethodName(kind === 'math' ? '前提·推理·反例' : '人物·事件·证据链');
    setMethodDescription(kind === 'math' ? '把每个推导拆成可核对的小步，再寻找边界情况。' : '先核对叙事中的对象、时间和地点，再整理关联。');
    setMethodSteps(kind === 'math' ? '逐段概括前提与结论\n核对每次变换的理由\n记录反例或边界条件\n关联定理与原文出处' : '逐段概括叙事\n提取人物、地点和事件\n核对时间与原文依据\n调用地图与关系组件');
    setMethodError('');
    setMethodOpen(true);
  }

  const statusLabel = running ? '正在逐段精读' : workflow.status === 'paused' ? '已暂停，可继续' : workflow.status === 'error' ? '有一段需要重试' : workflow.status === 'completed' ? '本轮回执已齐全' : planReady ? '方案就绪' : '先看看这本书';

  const readingSteps = kind === 'math' ? [
    ['cards','厘清概念与条件','区分定义、前提与结论，把符号条件留在原文旁。'],
    ['relations','连接推理的每一步','沿证明与例题梳理依赖，不把解释当作专用验算。'],
    ['notes','形成自己的理解与问题','保留没读懂的地方，连接原句、笔记与概念导图。']
  ] : [
    ['relations','梳理人物与阵营','认识主要人物，理清各方势力的关系、立场与变化。'],
    ['map','标记战役的时间和地点','沿事件先后看清行动与条件；原文未写明的地点不补造。'],
    ['notes','连接前因后果与阅读笔记','把人物、事件与主题串联起来，留下自己的思考与出处。']
  ];
  return <section className="settings-page method-next-page" aria-label="读书方法交互稿">
    <div className="method-next-scroll"><header className="method-next-heading"><p className="method-eyebrow">为这本书，找到合适的读法</p><h1>怎样读这本书</h1><p className="method-book-types">{bookTypes.length?bookTypes.join(' · '):'选择这本书的类型'}</p><p className="method-introduction">{kind==='math'?'沿概念、条件与推理，慢慢读出自己的理解。':'跟随人物与战役，沿时间和地点读懂故事。'}</p></header>
    <div className="method-reading-steps">{readingSteps.map(([icon,title,detail],i)=><article key={title}><span className="method-step-icon"><Icon name={icon} size={32}/></span><span className="method-step-number">0{i+1}</span><div><h2>{title}</h2><p>{detail}</p></div></article>)}</div>
    <div className="method-output-links">{(kind==='math'?[['mindmap','概念导图'],['relations','推理关联'],['notes','我的笔记']]:[['map','时间与地图'],['mindmap','思维导图'],['relations','关系图谱']]).map(([route,title])=><Button icon={route} variant="quiet" key={route} onClick={()=>navigate(route)}>{title}</Button>)}</div>
    <details className="method-processing glass" open={processingOpen} onToggle={e=>setProcessingOpen(e.currentTarget.open)}><summary><Icon name="info" size={18}/><span>处理详情</span><small>按需查看原文覆盖、疑点与工具记录</small><Icon name="chevronDown" size={17}/></summary><div className="method-processing-body"><p className="ps-helper">后台仍按原文清单逐段处理。回执只能检查处理覆盖，不能证明理解绝无遗漏；这里是本地示例队列。</p><div className="ps-workflow-actions"><Button icon="sparkle" disabled={running} onClick={makePlan}>{planReady?'重新建议读法 · 演示':'预读并建议读法 · 演示'}</Button><label className="ps-simulation-option"><input type="checkbox" checked={simulateFailure} disabled={running} onChange={e=>setSimulateFailure(e.target.checked)}/>演示一次中断</label></div><div className="ps-receipt-list">{segments.map(([page,paragraph,text],index)=>{const id=`${book.id}-p${page}-${paragraph}`,receipt=receipts.find(r=>r.id===id),isCurrent=running&&index===(workflow.cursor||0),expanded=expandedReceipt===id;return <article key={id} className={'ps-receipt '+(isCurrent?'is-current':'')}><button className="ps-receipt-row" aria-expanded={expanded} onClick={()=>setExpandedReceipt(expanded?'':id)}><span className={'ps-receipt-check '+(receipt?.status==='done'?'is-done':'')}><Icon name={receipt?.status==='done'?'check':receipt?.status==='failed'?'warning':'clock'} size={18}/></span><span className="ps-receipt-location">第 {page} 页 · 第 {paragraph} 段</span><span className="ps-receipt-summary">{receipt?.summary||(receipt?.status==='failed'?'待重试':isCurrent?'正在阅读…':'等待顺序处理')}</span><Icon name={expanded?'chevronDown':'chevronRight'} size={17}/></button>{expanded?<div className="ps-receipt-detail"><blockquote>{text}</blockquote>{receipt?.summary?<p>{receipt.summary}</p>:null}<Button icon="return" variant="quiet" onClick={()=>navigate('reader',{page:Number(page),source:{page:Number(page),paragraph:Number(paragraph),text}})}>回到这一段</Button></div>:null}</article>;})}</div><button className="ps-disclosure" aria-expanded={showLog} onClick={()=>setShowLog(v=>!v)}><Icon name="chevronDown" size={18}/>工具记录 · {workflow.pluginLog?.length||0}</button>{showLog?<div className="ps-plugin-log">{workflow.pluginLog?.length?workflow.pluginLog.map(log=><div key={log.id}><Icon name="check" size={16}/><p><strong>{log.plugin}</strong>{log.action}</p></div>):<p>完成这轮原文处理后，才会在这里显示示例产物回执。</p>}</div>:null}</div></details></div>
    <div className="method-status-dock glass" role="status"><div className="method-status-copy"><Icon name={running?'refresh':workflow.status==='error'?'warning':'book'}/><span>{running?'正在读':workflow.status==='paused'?'已暂停':workflow.status==='error'?'这一处需要重试':workflow.status==='completed'?'这一轮已读完':'读法已准备好'}</span><b>{running?`第 ${segments[Math.min(workflow.cursor||0,segments.length-1)][0]} 页`:book.title}</b></div><progress max={segments.length} value={completed} aria-label="当前处理进度"/><span className="method-status-percent">{Math.round(completed/segments.length*100)}%</span><Button icon={running?'pause':'play'} onClick={()=>actionRef.current()}>{running?'暂停':!planReady?'采用建议读法':workflow.status==='error'?'重试':'开始 / 继续'}</Button><Button icon="book" variant="primary" onClick={()=>navigate('reader')}>继续阅读</Button></div>
    {methodOpen?<Panel id="reading-method" title="调整读法" width={360} dock="right" initial={{x:Math.max(76,width-390),y:106}} onVisibilityChange={setMethodVisible} className="method-adjust-panel"><p className="method-adjust-intro">选择这本书的类型，可以组合。AI 会据此建议合适的理解方向与组件。</p><div className="method-type-options">{[...new Set(['历史','战争','小说','论述/研究','教材',...bookTypes])].map(type=><label className={bookTypes.includes(type)?'is-selected':''} key={type}><input type="checkbox" checked={bookTypes.includes(type)} disabled={running} onChange={()=>toggleBookType(type)}/><span>{type}</span></label>)}</div><form className="method-custom-type" onSubmit={e=>{e.preventDefault();const name=customType.trim();if(name&&!bookTypes.includes(name)){toggleBookType(name);setCustomType('');}}}><input aria-label="自定义书型" placeholder="自定义书型…" value={customType} disabled={running} onChange={e=>setCustomType(e.target.value)}/><Button type="submit" icon="plus" aria-label="添加自定义书型" disabled={!customType.trim()||running}/></form><details className="method-custom-details"><summary>选择或自定义具体读法<Icon name="chevronDown" size={16}/></summary><div className="ps-method-form"><label>当前方法<select value={editingMethodId} disabled={running} onChange={e=>{selectMethod(e.target.value);if(e.target.value==='new'){setMethodName('');setMethodDescription('');setMethodSteps('');}}}>{methods.map(method=><option key={method.id} value={method.id}>{method.name}</option>)}<option value="new">＋ 自定义方法</option></select></label><Button icon="sparkle" variant="quiet" disabled={running} onClick={suggestMethod}>建议另一种读法 · 演示</Button><label>名称<input value={methodName} disabled={running} onChange={e=>setMethodName(e.target.value)}/></label><label>目标<textarea rows={2} value={methodDescription} disabled={running} onChange={e=>setMethodDescription(e.target.value)}/></label><label>步骤 · 每行一项<textarea rows={5} value={methodSteps} disabled={running} onChange={e=>setMethodSteps(e.target.value)}/></label>{methodError?<p className="ps-error" role="alert">{methodError}</p>:null}<Button icon="save" variant="primary" disabled={running} onClick={saveMethod}>保存并用于本轮</Button></div></details><p className="method-adjust-note">{running?'正在处理时先暂停，再调整读法。':'变化仅保存在本次交互稿；不调用真实 AI。'}</p></Panel>:null}
  </section>;
}
