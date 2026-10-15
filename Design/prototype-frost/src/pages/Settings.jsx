import React, { useCallback, useEffect, useRef, useState } from 'react';
import { useApp, Icon, Button, Panel, Modal, Empty } from '../shared.jsx';
import './settings.css';

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

export function PluginsPage() {
  const { state, update, navigate, notify, book } = useApp();
  const width = useWindowWidth();
  const [query, setQuery] = useState('');
  const [tab, setTab] = useState('installed');
  const [typesOpen, setTypesOpen] = useState(() => window.innerWidth >= 1100);
  const [typesVisible, setTypesVisible] = useState(() => window.innerWidth >= 1100);
  const [selectedType, setSelectedType] = useState('');
  const [typeName, setTypeName] = useState('');
  const [typeFields, setTypeFields] = useState('');
  const [typeError, setTypeError] = useState('');
  const [importOpen, setImportOpen] = useState(false);
  const [importError, setImportError] = useState('');
  const [packageText, setPackageText] = useState(JSON.stringify({ id: 'translation', name: '译注对照', version: '1.0', capabilities: ['reading.layers'] }, null, 2));
  const types = (state.typeDefinitions || []).filter(t => t.bookId === book.id);
  const enabled = state.enabledPlugins || [];
  const added = state.addedComponents || [];
  const available = COMPONENTS.filter(c => !added.includes(c.id));

  useEffect(() => {
    const type = types.find(t => t.id === selectedType) || types[0];
    setSelectedType(type?.id || 'new');
    setTypeName(type?.name || '');
    setTypeFields(type?.fields?.join('、') || '');
    setTypeError('');
  }, [book.id]);

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
    const name = typeName.trim();
    const fields = [...new Set(typeFields.split(/[、,，\n]/).map(s => s.trim()).filter(Boolean))];
    if (!name || !fields.length) { setTypeError('请填写类型名称和至少一个字段。'); return; }
    if (types.some(t => t.name === name && t.id !== selectedType)) { setTypeError('本书已经有这个类型，请选择现有类型编辑。'); return; }
    const id = selectedType === 'new' ? `type-${Date.now()}` : selectedType;
    update(prev => ({ ...prev, typeDefinitions: [...(prev.typeDefinitions || []).filter(t => t.id !== id), { id, bookId: book.id, name, fields, origin: selectedType === 'new' ? '自定义' : types.find(t => t.id === id)?.origin || '自定义' }] }));
    setSelectedType(id);
    setTypeError('');
    notify(`已保存“${name}”示例类型，精读流程会使用本书类型。`);
  }

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

  return <section className="settings-page ps-plugins" aria-label="插件与组件交互稿">
    <div className={`ps-workspace ${typesVisible && width >= 1100 ? 'ps-with-aside' : ''}`}>
      <div className="ps-main-surface">
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
        <div className="ps-panel-note"><span><Icon name="info" size={18} />停用插件保留已有内容</span><Button variant="quiet" onClick={() => { setTypesOpen(true); setTypesVisible(true); window.dispatchEvent(new CustomEvent('prototype-panel-open', { detail: { id: 'plugin-types' } })); }} icon="cards">卡片类型</Button><Button variant="quiet" onClick={() => navigate('workflow')} icon="workflow">阅读方法</Button></div>
      </div>
    </div>
    {typesOpen && <Panel id="plugin-types" title="AI 定义的类型" width={360} dock="right" initial={{ x: Math.max(76, width - 390), y: 110 }} onVisibilityChange={setTypesVisible}>
      <div className="ps-type-form"><label>当前图书<span className="ps-read-value">{book.title}</span></label><label>选择类型<select value={selectedType} onChange={e => selectType(e.target.value)}>{types.map(type => <option key={type.id} value={type.id}>{type.name}</option>)}<option value="new">＋ 新建类型</option></select></label><div className="ps-type-suggestion"><Button variant="quiet" icon="sparkle" onClick={suggestType}>AI 建议 · 演示</Button></div><div className="ps-form-rule" /><label>名称<input value={typeName} onChange={e => setTypeName(e.target.value)} placeholder="由书决定，例如定理、战役" /></label><p className="ps-helper">按书定义，不限定为人物卡片。</p><label>字段<textarea value={typeFields} onChange={e => setTypeFields(e.target.value)} placeholder="用顿号或换行分隔" rows={4} /></label>{typeError && <p className="ps-error" role="alert">{typeError}</p>}<Button variant="primary" icon="save" onClick={saveType}>保存类型</Button><p className="ps-caption">此处修改示例数据；正式 App 实现另行验收。</p></div>
    </Panel>}
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
  const [listOpen, setListOpen] = useState(() => window.innerWidth > 1100);
  const [listVisible, setListVisible] = useState(() => window.innerWidth > 1100);
  const [newOpen, setNewOpen] = useState(false);
  const [pending, setPending] = useState(null);
  const testTimer = useRef(null);
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
  useEffect(() => { if (width <= 1100) { setListOpen(false); setListVisible(false); } }, [width]);
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
    setSaved(JSON.stringify(next));
    setError('');
    setTestState('idle');
    clearTimeout(testTimer.current);
    if (profile?.id) update(prev => ({ ...prev, activeProfileId: profile.id }));
    if (width <= 1100) { setListOpen(false); setListVisible(false); }
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
  const profileWidth = width > 1100 ? Math.min(850, width - 485) : Math.max(420, width - 112);

  return <section className="settings-page ps-models" aria-label="模型设置交互稿">
    {(!listOpen || !listVisible) && <div className="ps-service-reopen"><Button icon="models" onClick={() => { setListOpen(true); setListVisible(true); window.dispatchEvent(new CustomEvent('prototype-panel-open', { detail: { id: 'model-services' } })); }}>我的服务 · {state.profiles?.length || 0}</Button></div>}
    {listOpen && <Panel id="model-services" title="我的服务" width={350} className="ps-model-services" dock="left" initial={{ x: 80, y: 110 }} onVisibilityChange={setListVisible}><div className="ps-profile-list">{(state.profiles || []).map(profile => <button className={`ps-profile-row ${selectedId === profile.id ? 'is-selected' : ''}`} key={profile.id} onClick={() => requestLoad(profile)}><Icon name="link" size={26} /><span>{profile.name}</span>{state.activeProfileId === profile.id && <small>当前</small>}</button>)}{!state.profiles?.length && <p className="ps-helper">还没有保存的服务。</p>}<div className="ps-form-rule" /><Button variant="quiet" icon="plus" onClick={() => dirty ? setPending({ kind: 'new' }) : setNewOpen(true)}>新建服务</Button>{width <= 1100 && <Button variant="quiet" icon="collapse" onClick={() => { setListOpen(false); setListVisible(false); }}>返回配置</Button>}</div></Panel>}
    {(width > 1100 || !listOpen || !listVisible) && <Panel id="model-config" title={draft.name || '新服务配置'} className="ps-model-config" width={profileWidth} dock="right" initial={{ x: width > 1100 ? 455 : 78, y: width > 1100 ? 110 : 126 }}>
      <div className="ps-model-form">
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
        {error && <p className="ps-error" role="alert"><Icon name="warning" size={18} />{error}</p>}
        {testState !== 'idle' && <div className={`ps-test-result ${testState === 'error' ? 'is-error' : ''}`} role="status"><Icon name={testState === 'testing' ? 'refresh' : testState === 'success' ? 'check' : 'warning'} size={20} /><div><strong>{testState === 'testing' ? '正在演示测试…' : testState === 'success' ? '演示连接成功' : '演示连接失败'}</strong><p>{testState === 'error' ? '示例错误：模型 ID 未被服务接受。请检查输入后重试，草稿仍在。' : '仅演示界面状态，没有发起真实请求，也没有验证 OCR。'}</p></div></div>}
        <div className="ps-model-actions"><Button icon="play" variant="primary" disabled={testState === 'testing'} onClick={testConfig}>{testState === 'testing' ? '演示测试中…' : '测试配置 · 演示'}</Button><Button icon="trash" variant="quiet" disabled={!selectedId} onClick={deleteProfile} aria-label="删除当前示例配置" /></div><div className="ps-test-options"><Icon name="info" size={17} /><span>不发真实请求</span><label>演示结果<select value={testOutcome} onChange={e => setTestOutcome(e.target.value)}><option value="success">成功</option><option value="error">失败</option></select></label></div>
      </div>
    </Panel>}
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
  const workflow = state.workflow || { status: 'idle', receipts: [], pluginLog: [], methodId: 'close', cursor: 0 };
  const methods = state.readingMethods || [];
  const [methodOpen, setMethodOpen] = useState(() => window.innerWidth >= 1100);
  const [methodVisible, setMethodVisible] = useState(() => window.innerWidth >= 1100);
  const [editingMethodId, setEditingMethodId] = useState(workflow.methodId || methods[0]?.id || 'close');
  const [methodName, setMethodName] = useState('');
  const [methodDescription, setMethodDescription] = useState('');
  const [methodSteps, setMethodSteps] = useState('');
  const [methodError, setMethodError] = useState('');
  const [simulateFailure, setSimulateFailure] = useState(false);
  const [expandedReceipt, setExpandedReceipt] = useState('');
  const [showLog, setShowLog] = useState(false);
  const [planReady, setPlanReady] = useState(!!workflow.planReady);
  const kind = book.id === 'math' ? 'math' : 'history';
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
    window.addEventListener('prototype-primary', primary);
    return () => window.removeEventListener('prototype-primary', primary);
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
    setMethodName(kind === 'math' ? '逐步验算与反例' : '人物·事件·证据链');
    setMethodDescription(kind === 'math' ? '把每个推导拆成可核对的小步，再寻找边界情况。' : '先核对叙事中的对象、时间和地点，再整理关联。');
    setMethodSteps(kind === 'math' ? '逐段概括前提与结论\n核对每次变换的理由\n记录反例或边界条件\n关联定理与原文出处' : '逐段概括叙事\n提取人物、地点和事件\n核对时间与原文依据\n调用地图与关系组件');
    setMethodError('');
    setMethodOpen(true);
  }

  const statusLabel = running ? '正在逐段精读' : workflow.status === 'paused' ? '已暂停，可继续' : workflow.status === 'error' ? '有一段需要重试' : workflow.status === 'completed' ? '本轮回执已齐全' : planReady ? '方案就绪' : '先看看这本书';

  return <section className="settings-page ps-workflow" aria-label="阅读流程交互稿"><div className={`ps-workspace ${methodVisible && width >= 1100 ? 'ps-with-aside' : ''}`}><div className="ps-main-surface ps-workflow-main"><div className="ps-workflow-heading"><div><span className="ps-eyebrow">READING WORKFLOW</span><h1>{statusLabel}</h1><p>{book.title} · 示例范围第 1–3 页，共 {segments.length} 段</p></div><Button icon="workflow" onClick={() => { setMethodOpen(true); setMethodVisible(true); window.dispatchEvent(new CustomEvent('prototype-panel-open', { detail: { id: 'reading-method' } })); }}>阅读方法</Button></div><div className="ps-workflow-progress"><div><strong>{completed}<span> / {segments.length} 段</span></strong><span>{currentMethod?.name || '未选方法'}</span></div><progress max={segments.length} value={completed} aria-label="已取得段落回执的覆盖数" /></div><div className="ps-workflow-actions"><Button icon="sparkle" disabled={running} onClick={makePlan}>{planReady ? '重新预读选法' : '预读并选择方法'}</Button><Button variant="primary" icon={running ? 'pause' : 'play'} disabled={!planReady} onClick={() => actionRef.current()}>{running ? '暂停精读' : workflow.status === 'error' ? '重试这一段' : workflow.status === 'paused' ? '继续精读' : workflow.status === 'completed' ? '再演示一轮' : '开始逐段精读'}</Button><label className="ps-simulation-option"><input type="checkbox" checked={simulateFailure} disabled={running} onChange={e => setSimulateFailure(e.target.checked)} />演示一次失败</label></div>{workflow.status === 'error' && <div className="ps-error ps-workflow-error" role="alert"><Icon name="warning" size={20} /><span>{workflow.error} 已完成的回执保留，不跳过失败段。</span></div>}<div className="ps-coverage-explainer"><Icon name="info" size={18} /><p>每段都有独立编号、原文和一句回执；缺失段不能算完成。这能检查处理覆盖，不能证明 AI 理解无遗漏。离开流程页会暂停本地演示，回来可继续。</p></div><div className="ps-ledger-heading"><h2>逐页逐段清单</h2><span>先逐段，再整理关联</span></div><div className="ps-receipt-list">{segments.map(([page, paragraph, text], index) => {
      const id = `${book.id}-p${page}-${paragraph}`;
      const receipt = receipts.find(r => r.id === id);
      const isCurrent = running && index === (workflow.cursor || 0);
      const expanded = expandedReceipt === id;
      return <article key={id} className={`ps-receipt ${isCurrent ? 'is-current' : ''} ${receipt?.status === 'failed' ? 'is-failed' : ''}`}><button className="ps-receipt-row" aria-expanded={expanded} onClick={() => setExpandedReceipt(expanded ? '' : id)}><span className={`ps-receipt-check ${receipt?.status === 'done' ? 'is-done' : ''}`}><Icon name={receipt?.status === 'done' ? 'check' : receipt?.status === 'failed' ? 'warning' : isCurrent ? 'refresh' : 'clock'} size={18} /></span><span className="ps-receipt-location">第 {page} 页 · 第 {paragraph} 段</span><span className="ps-receipt-summary">{receipt?.summary || (receipt?.status === 'failed' ? '回执失败，待重试' : isCurrent ? '正在读取这一段…' : '等待按顺序读取')}</span><Icon name={expanded ? 'chevronDown' : 'chevronRight'} size={17} /></button>{expanded && <div className="ps-receipt-detail"><blockquote>{text}</blockquote>{receipt?.summary && <p><strong>简短回执</strong>{receipt.summary}</p>}<Button icon="return" variant="quiet" onClick={() => navigate('reader', { source: { page: Number(page), paragraph: Number(paragraph), text } })}>回到第 {page} 页原段</Button></div>}</article>;
    })}</div><div className="ps-workflow-bottom"><button className="ps-disclosure" aria-expanded={showLog} onClick={() => setShowLog(!showLog)}><Icon name={showLog ? 'chevronDown' : 'chevronRight'} size={18} />插件调用记录 <span>{workflow.pluginLog?.length || 0}</span></button>{showLog && <div className="ps-plugin-log">{workflow.pluginLog?.length ? workflow.pluginLog.map(log => <div key={log.id}><Icon name="check" size={16} /><p><strong>{log.plugin}</strong>{log.action}</p></div>) : <p className="ps-helper">先取得所有段落回执，再模拟提取要素和调用插件。停用的插件不会参与。</p>}</div>}<p className="ps-caption">本书可选类型：{activeTypeNames.join('、') || '尚未定义，可到插件页新建'}。数学书不会自动生成人物卡。</p></div></div></div>{methodOpen && <Panel id="reading-method" title="阅读方法" width={360} dock="right" initial={{ x: Math.max(76, width - 390), y: 110 }} onVisibilityChange={setMethodVisible}><div className="ps-method-form"><label>当前方法<select value={editingMethodId} disabled={running} onChange={e => { selectMethod(e.target.value); if (e.target.value === 'new') { setMethodName(''); setMethodDescription(''); setMethodSteps(''); } }}>{methods.map(method => <option key={method.id} value={method.id}>{method.name}</option>)}<option value="new">＋ 自定义方法</option></select></label><Button icon="sparkle" variant="quiet" disabled={running} onClick={suggestMethod}>让 AI 建议一种 · 演示</Button><div className="ps-form-rule" /><label>名称<input value={methodName} disabled={running} onChange={e => setMethodName(e.target.value)} /></label><label>目标<textarea rows={2} value={methodDescription} disabled={running} onChange={e => setMethodDescription(e.target.value)} /></label><label>执行步骤<textarea rows={6} value={methodSteps} disabled={running} onChange={e => setMethodSteps(e.target.value)} /></label><p className="ps-helper">每行一步。所有方法都先核对段落回执，再执行这些整理动作。</p>{methodError && <p className="ps-error" role="alert">{methodError}</p>}<Button icon="save" variant="primary" disabled={running} onClick={saveMethod}>保存并用于本轮</Button></div></Panel>}</section>;
}
