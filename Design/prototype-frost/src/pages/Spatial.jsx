import React, { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { useApp, Icon, Button, Panel, Toolbar, Modal, Markdown, Empty, placeFloatingChrome } from '../shared.jsx';
import './spatial.css';

export const SPATIAL_EVENTS = [
  { id: 'h-jiangxia', name: '江夏相会', year: 208, place: '夏口', x: 1170, y: 300, chapter: '第四十二回', page: 42, people: ['刘备', '诸葛亮', '刘琦'], text: '刘备一行抵达夏口，商议联合江东。', quote: '孔明曰：“今曹操拥百万之众，挟天子以令诸侯，此诚不可与争锋。”' },
  { id: 'h-retreat', name: '江陵至华容', year: 208, place: '华容', x: 610, y: 445, chapter: '第五十回', page: 50, people: ['曹操', '关羽'], text: '赤壁之后的撤退路线，串联起战役与人物的选择。', quote: '操引众将奔华容道而去。' },
  { id: 'h-redcliff', name: '赤壁之战', year: 208, place: '赤壁', x: 925, y: 490, chapter: '第四十九回', page: 49, people: ['周瑜', '诸葛亮', '黄盖', '曹操'], text: '孙刘联军在此迎战曹操。火攻与联盟共同改变了战局。', quote: '时东南风急，黄盖将中军船帆扯足，望曹操水寨，乘风而去。' },
  { id: 'h-jiangling', name: '江陵之争', year: 209, place: '江陵', x: 240, y: 325, chapter: '第五十一回', page: 51, people: ['周瑜', '刘备', '曹仁'], text: '赤壁之后，围绕荆州的争夺继续展开。', quote: '却说周瑜大军来到南郡，前面军马屯住。' },
  { id: 'h-jingzhou', name: '荆州局势', year: 211, place: '荆州', x: 450, y: 230, chapter: '第六十回', page: 60, people: ['刘备', '孙权'], text: '地理位置与联盟关系持续影响各方决策。', quote: '荆州一事，尚须从长计议。' },
  { id: 'h-uncertain', name: '一则年代待考的军议', year: null, place: '地点待考', x: null, y: null, chapter: '读书札记', page: 49, people: ['诸葛亮'], text: '这条示例尚未确认时间与坐标，保留在待考清单中，不在地图上制造精确位置。', quote: '' },
].map((event) => ({ ...event, title: event.name, page: event.id === 'h-retreat' ? 2 : event.id === 'h-jiangling' || event.id === 'h-jingzhou' ? 3 : 1, source: { page: event.id === 'h-retreat' ? 2 : event.id === 'h-jiangling' || event.id === 'h-jingzhou' ? 3 : 1, chapter: event.chapter, paragraph: 2, text: event.quote || event.text } }));
const EVENTS = SPATIAL_EVENTS;
const NARRATIVE_SEQUENCE = ['h-jiangling', 'h-retreat', 'h-redcliff'];
const PEOPLE = {
  刘备: '孙刘联盟的一方。人物的立场与行动需要结合前后章节理解。',
  诸葛亮: '在联盟与战略讨论中出现。此处展示共享对象的示例资料。',
  周瑜: '江东统帅。参与联盟与赤壁战役的谋划。',
  黄盖: '赤壁火攻的执行者之一。',
  曹操: '率军南下。战前部署与战后撤退在同一时空线索中连接。',
  关羽: '在华容道叙事中作出关键选择。',
  刘琦: '江夏线索中的人物。',
  曹仁: '南郡防御的参与者。',
  孙权: '江东一方的决策者。',
};
const MIN_YEAR = 207;
const MAX_YEAR = 211;
const NODE_W = 232;
const NODE_H = 100;
const COMPACT_SEEDS = {
  'n-h-main': { old: [480, 440], next: [350, 430] },
  'n-h-alliance': { old: [160, 220], next: [70, 220] },
  'n-h-fire': { old: [800, 220], next: [650, 220] },
  'n-h-people': { old: [120, 590], next: [25, 610] },
  'n-h-question': { old: [850, 590], next: [680, 610] },
  'n-h-understanding': { old: [520, 760], next: [385, 800] },
  'n-math-note': { old: [330, 330], next: [320, 420] },
  'n-m-pivot': { old: [720, 200], next: [620, 220] },
  'n-m-matrix': { old: [740, 540], next: [620, 620] },
  'n-m-question': { old: [180, 610], next: [40, 620] },
};
const isOriginalSeed = (node) => { const seed = COMPACT_SEEDS[node.id]; return !node.frostSeedLayout && seed && node.x === seed.old[0] && node.y === seed.old[1]; };
const clamp = (value, min, max) => Math.min(max, Math.max(min, value));
const textSummary = (value = '') => value.replace(/[#*`>$]/g, '').replace(/\s+/g, ' ').trim().slice(0, 84);
const openPanel = (id) => window.dispatchEvent(new CustomEvent('prototype-panel-open', { detail: { id } }));

function useViewport(ref) {
  const [size, setSize] = useState({ x: 0, y: 0, width: 0, height: 0, ready: false });
  useLayoutEffect(() => {
    const node = ref.current;
    if (!node) return undefined;
    const measure = () => {
      const rect = node.getBoundingClientRect();
      setSize((previous) => previous.x === rect.x && previous.y === rect.y && previous.width === rect.width && previous.height === rect.height && previous.ready
        ? previous : { x: rect.x, y: rect.y, width: rect.width, height: rect.height, ready: true });
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(node);
    return () => observer.disconnect();
  }, [ref]);
  return size;
}

const sameFrame = (a, b) => a === b || Boolean(a && b && a.x === b.x && a.y === b.y && a.w === b.w && a.h === b.h);
function useStableFrame() {
  const [frame, setFrame] = useState(null);
  const receive = useCallback((next) => setFrame((previous) => sameFrame(previous, next) ? previous : next), []);
  return [frame, receive];
}
function useIntrinsicSize(ref) {
  const [size, setSize] = useState({ w: 0, h: 0 });
  useLayoutEffect(() => {
    const element = ref.current;
    if (!element) return undefined;
    const measure = () => { const rect = element.getBoundingClientRect(); setSize((previous) => previous.w === rect.width && previous.h === rect.height ? previous : { w: rect.width, h: rect.height }); };
    measure();
    const observer = new ResizeObserver(measure); observer.observe(element);
    return () => observer.disconnect();
  }, [ref]);
  return size;
}
function useNavigationObstacle() {
  const [frame, receiveFrame] = useStableFrame();
  useLayoutEffect(() => {
    let request = 0;
    const measure = () => { const rect = document.querySelector('.nav-handle,.nav-dot')?.getBoundingClientRect(); receiveFrame(rect ? { x: rect.x, y: rect.y, w: rect.width, h: rect.height } : null); };
    const settled = () => { cancelAnimationFrame(request); request = requestAnimationFrame(measure); };
    measure();
    window.addEventListener('pointerup', settled); window.addEventListener('resize', settled);
    return () => { cancelAnimationFrame(request); window.removeEventListener('pointerup', settled); window.removeEventListener('resize', settled); };
  }, [receiveFrame]);
  return frame;
}
const chromeBounds = (size) => ({ x: size.x + 20, y: size.y + 88, w: Math.max(0, size.width - 40), h: Math.max(0, size.height - 112) });
const fixedFrameStyle = (frame) => frame ? { left: frame.x, top: frame.y, width: frame.w, height: frame.h } : { visibility: 'hidden' };
function SpatialChrome({ viewport, obstacles, full, compact, menu, status, statusText = '', align = 'center', onToolbarFrameChange }) {
  const fullRef = useRef(null), compactRef = useRef(null), menuRef = useRef(null), statusRef = useRef(null);
  const fullSize = useIntrinsicSize(fullRef), compactSize = useIntrinsicSize(compactRef), menuSize = useIntrinsicSize(menuRef), statusSize = useIntrinsicSize(statusRef);
  const navigationFrame = useNavigationObstacle();
  const blocked = [...obstacles, navigationFrame].filter(Boolean);
  const bounds = chromeBounds(viewport);
  let toolbarFrame = null, mode = 'menu';
  for (const [candidateMode, size] of [['full', fullSize], ['compact', compactSize], ['menu', menuSize]]) {
    const preferred = { x: align === 'right' ? bounds.x + bounds.w - size.w : bounds.x + (bounds.w - size.w) / 2, y: bounds.y + bounds.h - size.h };
    const candidate = placeFloatingChrome(size, preferred, bounds, blocked);
    if (candidate) { toolbarFrame = candidate; mode = candidateMode; break; }
  }
  const statusFrame = status ? placeFloatingChrome(statusSize, { x: bounds.x, y: bounds.y + bounds.h - statusSize.h }, bounds, [...blocked, toolbarFrame].filter(Boolean)) : null;
  const toolbarToken = JSON.stringify(toolbarFrame), statusToken = JSON.stringify(statusFrame);
  const callback = useRef(onToolbarFrameChange); callback.current = onToolbarFrameChange;
  useLayoutEffect(() => { callback.current?.(toolbarFrame); }, [toolbarToken]);
  useEffect(() => { window.dispatchEvent(new CustomEvent('prototype-chrome-settled')); }, [toolbarToken, statusToken]);
  return <>
    <div className="spatial-chrome-measure" aria-hidden="true">
      <div ref={fullRef}><Toolbar className="spatial-measured-toolbar">{full}</Toolbar></div>
      <div ref={compactRef}><Toolbar className="spatial-measured-toolbar">{compact}</Toolbar></div>
      <div ref={menuRef}><Toolbar className="spatial-measured-toolbar">{menu}</Toolbar></div>
      <div ref={statusRef} className="glass spatial-placed-status spatial-measured-status" style={{ maxWidth: Math.min(300, Math.max(0, bounds.w)) }}>{status}</div>
    </div>
    {toolbarFrame ? <div className="spatial-placed-toolbar" style={fixedFrameStyle(toolbarFrame)} data-settled-frame={toolbarToken} title={statusText}><Toolbar>{mode === 'full' ? full : mode === 'compact' ? compact : menu}</Toolbar></div> : null}
    {statusFrame ? <div className="glass spatial-placed-status" style={fixedFrameStyle(statusFrame)} data-settled-frame={statusToken}>{status}</div> : null}
  </>;
}

function TimeAxis({ range, onChange, cursor, onCursor, events, selectedId, onSelect }) {
  const axisRef = useRef(null);
  const dragRef = useRef(null);
  const [active, setActive] = useState(null);
  const crowded = range[1] - range[0] < 0.12;
  const percent = (year) => ((year - MIN_YEAR) / (MAX_YEAR - MIN_YEAR)) * 100;
  const adjust = (endpoint, value) => endpoint === 2 ? onCursor(clamp(value, range[0], range[1])) : onChange(endpoint === 0 ? [clamp(value, MIN_YEAR, range[1]), range[1]] : [range[0], clamp(value, range[0], MAX_YEAR)]);
  const start = (event, endpoint) => {
    event.preventDefault();
    event.stopPropagation();
    const rect = axisRef.current.getBoundingClientRect();
    dragRef.current = { endpoint, x: event.clientX, origin: endpoint === 2 ? cursor : range[endpoint], range: [...range], width: rect.width };
    event.currentTarget.setPointerCapture(event.pointerId);
    setActive(endpoint);
  };
  const move = (event) => {
    const drag = dragRef.current;
    if (!drag) return;
    const value = Math.round(drag.origin + (event.clientX - drag.x) / drag.width * (MAX_YEAR - MIN_YEAR));
    if (drag.endpoint === 2) { onCursor(clamp(value, range[0], range[1])); return; }
    const next = [...drag.range];
    next[drag.endpoint] = drag.endpoint === 0 ? clamp(value, MIN_YEAR, next[1]) : clamp(value, next[0], MAX_YEAR);
    onChange(next);
  };
  const finish = () => { dragRef.current = null; setActive(null); };
  useEffect(() => {
    const cancel = (event) => { if (event.key === 'Escape') finish(); };
    window.addEventListener('keydown', cancel);
    window.addEventListener('blur', finish);
    window.addEventListener('resize', finish);
    return () => { window.removeEventListener('keydown', cancel); window.removeEventListener('blur', finish); window.removeEventListener('resize', finish); };
  }, []);
  return <div className="spatial-axis-wrap">
    <div className="spatial-axis" ref={axisRef}>
      <div className="spatial-axis-track" />
      <div className="spatial-axis-selected" style={{ left: `${percent(range[0])}%`, width: `${percent(range[1]) - percent(range[0])}%` }} />
      {[207, 208, 209, 210, 211].map((year) => <span className="spatial-axis-tick" key={year} style={{ left: `${percent(year)}%` }}><i /><span>{year}年</span></span>)}
      {events.filter((event) => event.year !== null).map((event, index) => <button className={`spatial-axis-event ${selectedId === event.id ? 'is-selected' : ''}`} key={event.id} style={{ left: `${percent(event.year)}%`, top: index % 2 ? 12 : 2 }} aria-label={`${event.year}年，${event.name}`} title={`${event.year}年 · ${event.name}`} onClick={() => onSelect(event)} />)}
      {[0, 1].map((endpoint) => <button key={endpoint} className={`spatial-axis-thumb ${active === endpoint ? 'is-active' : ''}`} style={{ left: `${percent(range[endpoint])}%`, top: crowded ? (endpoint === 0 ? -5 : 17) : 6 }} role="slider" aria-label={endpoint === 0 ? '时间范围起点' : '时间范围终点'} aria-valuemin={endpoint === 0 ? MIN_YEAR : range[0]} aria-valuemax={endpoint === 0 ? range[1] : MAX_YEAR} aria-valuenow={range[endpoint]} aria-valuetext={`${range[endpoint]}年`} onPointerDown={(event) => start(event, endpoint)} onPointerMove={move} onPointerUp={finish} onPointerCancel={finish} onKeyDown={(event) => {
        if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') { event.preventDefault(); adjust(endpoint, range[endpoint] + (event.key === 'ArrowRight' ? 1 : -1)); }
        if (event.key === 'Home') { event.preventDefault(); adjust(endpoint, MIN_YEAR); }
        if (event.key === 'End') { event.preventDefault(); adjust(endpoint, MAX_YEAR); }
      }} />)}
      <button className="spatial-time-cursor" style={{ left: `${percent(cursor)}%` }} role="slider" aria-label="当前时间" aria-valuemin={range[0]} aria-valuemax={range[1]} aria-valuenow={cursor} aria-valuetext={`${cursor}年`} onPointerDown={(event) => start(event, 2)} onPointerMove={move} onPointerUp={finish} onPointerCancel={finish} onKeyDown={(event) => {
        if (['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) { event.preventDefault(); adjust(2, event.key === 'Home' ? range[0] : event.key === 'End' ? range[1] : cursor + (event.key === 'ArrowRight' ? 1 : -1)); }
      }}><span>{cursor}年</span></button>
    </div>
  </div>;
}

export function MapPage() {
  const { state, update, navigate, book } = useApp();
  const viewportRef = useRef(null);
  const size = useViewport(viewportRef);
  const mapNavigationFrame = useNavigationObstacle();
  const [timelineFrame, receiveTimelineFrame] = useStableFrame();
  const [personFrame, receivePersonFrame] = useStableFrame();
  const [mapToolbarFrame, receiveMapToolbarFrame] = useStableFrame();
  const [camera, setCamera] = useState({ x: 720, y: 512, scale: 1 });
  const panRef = useRef(null);
  const [selectedId, setSelectedId] = useState('h-redcliff');
  const [detailOpen, setDetailOpen] = useState(true);
  const [eventListOpen, setEventListOpen] = useState(false);
  const [query, setQuery] = useState('');
  const [optionsOpen, setOptionsOpen] = useState(false);
  const [rangeEditor, setRangeEditor] = useState(false);
  const [rangeDraft, setRangeDraft] = useState(['208', '209']);
  const [rangeError, setRangeError] = useState('');
  const [showUndated, setShowUndated] = useState(true);
  const [inspectedPerson, setInspectedPerson] = useState(null);
  const [mapToolsOpen, setMapToolsOpen] = useState(false);
  const timelineIsTop = timelineFrame ? timelineFrame.y < size.y + 132 : false;
  let maximumTimelineHeight = Math.min(520, Math.max(56, size.height - 120));
  if (size.width < 1050 && inspectedPerson && personFrame) {
    maximumTimelineHeight = Math.min(maximumTimelineHeight, Math.max(56, size.height - (timelineIsTop ? 296 : 272)));
    // A previously dragged example panel may be between the snap points.
    // Keep a complete 140pt person slot without changing that saved position.
    if (timelineFrame && timelineFrame.y - size.y - 100 < 140) maximumTimelineHeight = Math.min(maximumTimelineHeight, Math.max(56, size.y + size.height - 176 - timelineFrame.y));
  }
  const inspectPerson = (person) => { setInspectedPerson(person); openPanel('map-person'); };
  const range = state.timeRange || [208, 209];
  const cursor = clamp(state.timeCursor ?? 208, range[0], range[1]);
  const personEvents = inspectedPerson ? EVENTS.filter((event) => event.people.includes(inspectedPerson) && event.year === cursor) : [];
  // Independently authored example presences, never every participant × place.
  const explicitPresenceIds = { '曹操': ['h-redcliff', 'h-retreat'], '周瑜': ['h-redcliff', 'h-jiangling'], '刘备': ['h-jiangxia', 'h-jingzhou'], '关羽': ['h-retreat'] };
  const scopedEvents = state.readingScope === 'current' ? EVENTS.filter((event) => event.id === 'h-redcliff' || event.id === 'h-uncertain') : EVENTS;
  const filteredEvents = scopedEvents.filter((event) => event.year === null ? showUndated : event.year >= range[0] && event.year <= range[1]);
  const visibleEventIds = new Set(filteredEvents.map((event) => event.id));
  const narrativeSegments = NARRATIVE_SEQUENCE.slice(1).flatMap((id, index) => {
    const fromId = NARRATIVE_SEQUENCE[index];
    if (!visibleEventIds.has(fromId) || !visibleEventIds.has(id)) return [];
    const from = EVENTS.find((event) => event.id === fromId); const to = EVENTS.find((event) => event.id === id);
    return [{ id: `${fromId}-${id}`, from, to }];
  });
  const selected = EVENTS.find((event) => event.id === selectedId);
  const plottedEvents = inspectedPerson ? personEvents.filter((event) => (explicitPresenceIds[inspectedPerson] || []).includes(event.id)) : filteredEvents;
  const selectedVisible = (inspectedPerson ? personEvents : filteredEvents).some((event) => event.id === selectedId);
  const fitMap = useCallback(() => { if (size.width > 0 && size.height > 0) setCamera({ x: 720, y: 512, scale: Math.max(size.width / 1440, size.height / 1024) }); }, [size.width, size.height]);
  useEffect(() => { fitMap(); }, [fitMap]);
  useEffect(() => {
    const viewport = viewportRef.current?.querySelector('.spatial-map-viewport');
    if (!viewport) return undefined;
    const wheel = (event) => event.preventDefault();
    const cancel = () => { panRef.current = null; };
    viewport.addEventListener('wheel', wheel, { passive: false });
    window.addEventListener('blur', cancel); window.addEventListener('resize', cancel);
    return () => { viewport.removeEventListener('wheel', wheel); window.removeEventListener('blur', cancel); window.removeEventListener('resize', cancel); };
  }, [book.id]);
  const selectEvent = (event) => {
    setSelectedId(event.id); setDetailOpen(true); setEventListOpen(false); openPanel('map-time');
    if (event.x !== null) setCamera((previous) => ({ ...previous, x: event.x - 60, y: event.y - 20 }));
  };
  useEffect(() => {
    if (state.selectedEventId) { const event = EVENTS.find((item) => item.id === state.selectedEventId); if (event) { setSelectedId(event.id); setDetailOpen(true); openPanel('map-time'); } }
  }, [state.selectedEventId]);
  const zoom = (factor, point = { x: size.width / 2, y: size.height / 2 }) => setCamera((previous) => {
    const nextScale = clamp(previous.scale * factor, 0.45, 4);
    const worldX = previous.x + (point.x - size.width / 2) / previous.scale;
    const worldY = previous.y + (point.y - size.height / 2) / previous.scale;
    return { x: worldX - (point.x - size.width / 2) / nextScale, y: worldY - (point.y - size.height / 2) / nextScale, scale: nextScale };
  });
  if (book.id !== 'history') return <div className="spatial-page spatial-empty-page" ref={viewportRef}><Empty icon="map" title="这本书还没有时空要素" action={<Button variant="primary" icon="map" onClick={() => update({ currentBookId: 'history' })}>查看《三国演义》示例</Button>}>数学书不会为了填满地图而生成人物或地点。可以继续阅读，或查看有事件与地点的历史书示例。</Empty></div>;
  return <div className="spatial-page spatial-map-page" ref={viewportRef}>
    <div className="spatial-map-viewport" aria-label="可拖动缩放的示意地图" onPointerDown={(event) => {
      if (event.button !== 0 || event.target.closest('button')) return;
      event.currentTarget.setPointerCapture(event.pointerId); panRef.current = { x: event.clientX, y: event.clientY, camera: { ...camera } };
    }} onPointerMove={(event) => {
      const pan = panRef.current; if (!pan) return;
      setCamera({ ...pan.camera, x: pan.camera.x - (event.clientX - pan.x) / pan.camera.scale, y: pan.camera.y - (event.clientY - pan.y) / pan.camera.scale });
    }} onPointerUp={() => { panRef.current = null; }} onPointerCancel={() => { panRef.current = null; }} onWheel={(event) => {
      const rect = event.currentTarget.getBoundingClientRect(); zoom(event.deltaY > 0 ? 0.92 : 1.08, { x: event.clientX - rect.left, y: event.clientY - rect.top });
    }}>
      <div className="spatial-map-world" style={{ transform: `translate(${size.width / 2 - camera.x * camera.scale}px,${size.height / 2 - camera.y * camera.scale}px) scale(${camera.scale})` }}>
        <img className="spatial-terrain" src="/assets/map-terrain.png" alt="浅石色地形与浅蓝水系，仅供空间布局示意" draggable="false" />
        <svg className="spatial-map-narrative" width="1440" height="1024" aria-hidden="true">{(inspectedPerson ? [] : narrativeSegments).map(({ id, from, to }) => {
          const bend = (to.x - from.x) * 0.4;
          return <path key={id} d={`M ${from.x} ${from.y} C ${from.x + bend} ${from.y + 22}, ${to.x - bend} ${to.y - 16}, ${to.x} ${to.y}`} />;
        })}</svg>
        <span className="spatial-place-region" style={{ left: 360, top: 200 }}>荆 州</span><span className="spatial-place-region" style={{ left: 1000, top: 170 }}>江 夏</span><span className="spatial-water-name" style={{ left: 690, top: 520 }}>长　江</span><span className="spatial-water-name" style={{ left: 1050, top: 740 }}>洞庭湖</span>
        {plottedEvents.filter((event) => event.x !== null).map((event) => <button key={event.id} className={`spatial-map-marker ${selectedId === event.id ? 'is-selected' : ''}`} style={{ left: event.x, top: event.y }} onClick={() => selectEvent(event)} aria-label={`${event.name}，${event.year}年，${event.place}`}><span className="spatial-marker-dot"><Icon name={selectedId === event.id ? 'map' : 'clock'} size={selectedId === event.id ? 22 : 14} /></span><span className="spatial-marker-caption">{event.place}</span>{selectedId === event.id && <span className="spatial-marker-event">{event.name}</span>}</button>)}
      </div>
    </div>
    <div className="spatial-map-evidence">示例地形，非测绘依据<br />虚线为示例叙事顺序，非考证路线</div>
    <Panel toolbarRestore id="map-time" title="时间与地图" autoCollapseBelow={900} width={Math.min(740,Math.max(300,size.width-144))} maximumHeight={maximumTimelineHeight} avoidRects={mapNavigationFrame ? [{ ...mapNavigationFrame, w: mapNavigationFrame.w + 16 }] : []} onFrameChange={receiveTimelineFrame} dock="bottom-left" initial={{ x: 24, y: Math.max(96, window.innerHeight - (window.innerWidth < 900 ? 56 : 420) - 24) }} snap className="spatial-time-panel" actions={<Button icon="more" variant="quiet" aria-label="时间与地图选项" onClick={() => setOptionsOpen(true)} />}>
      <div className="spatial-time-summary"><button className="spatial-range-label" onClick={() => { setRangeDraft(range.map(String)); setRangeError(''); setRangeEditor(true); }}>{range[0]}年 — {range[1]}年 <Icon name="chevronDown" size={15} /></button><button className="spatial-text-button" onClick={() => setEventListOpen(true)}>{state.readingScope === 'current' ? '当前原文' : '全书'} · {filteredEvents.length} 个事件 <Icon name="chevronRight" size={15} /></button></div>
      <TimeAxis range={range} cursor={cursor} onCursor={(next) => update({ timeCursor: next })} onChange={(next) => update({ timeRange: next, timeCursor: clamp(cursor, next[0], next[1]) })} events={scopedEvents} selectedId={selectedId} onSelect={selectEvent} />
      {selected && detailOpen && <section className="spatial-event-detail"><div className="spatial-detail-kicker"><span>{selected.year ? `${selected.year}年` : '年代待考'} · {selected.place}</span><Button icon="collapse" variant="quiet" aria-label="收起事件详情" onClick={() => setDetailOpen(false)} /></div><div className="spatial-event-content"><div className="spatial-event-copy"><h2>{selected.name}</h2><p>{selected.text}</p>
        {!selectedVisible && <div className="spatial-inline-warning"><Icon name="filter" size={18} /><span>此事件不在当前范围。</span><button className="spatial-text-button" onClick={() => { update({ readingScope: 'book', ...(selected.year ? { timeRange: [selected.year, selected.year], timeCursor: selected.year } : {}) }); setShowUndated(true); }}>显示此事件</button></div>}
        {selected.x === null && <p className="spatial-muted">尚未确认坐标，未在地图上标点。</p>}
        </div><div className="spatial-person-links">{selected.people.map((person) => <button key={person} onClick={() => inspectPerson(person)}>{person}</button>)}</div></div>
        <div className="spatial-source-row"><span>{selected.chapter}</span><Button icon="book" onClick={() => navigate('reader', { page: selected.page, source: selected.source })}>回到原句</Button></div>
      </section>}
      {!detailOpen && <button className="spatial-restore-detail" onClick={() => setDetailOpen(true)}><Icon name="info" size={18} />{selected?.name || '查看事件详情'}<Icon name="chevronDown" size={16} /></button>}
    </Panel>
    <SpatialChrome viewport={size} obstacles={[timelineFrame].filter(Boolean)} align="right" onToolbarFrameChange={receiveMapToolbarFrame}
      full={<><Button icon="clock" aria-label="时间轴" title="时间轴" className={timelineFrame?'is-selected':''} onClick={()=>window.dispatchEvent(new CustomEvent(timelineFrame?'prototype-panel-close':'prototype-panel-open',{detail:{id:'map-time'}}))}/><span className="spatial-tool-divider"/><Button icon="target" aria-label="显示全部地图标记" onClick={fitMap} /><span className="spatial-tool-divider" /><Button icon="minus" aria-label="缩小地图" onClick={() => zoom(1 / 1.25)} /><Button icon="plus" aria-label="放大地图" onClick={() => zoom(1.25)} /></>}
      compact={<><Button icon="clock" aria-label="时间轴" onClick={()=>openPanel('map-time')}/><Button icon="target" aria-label="显示全部地图标记" onClick={fitMap} /><Button icon="more" aria-label="地图工具" onClick={() => setMapToolsOpen(true)} /></>}
      menu={<Button icon="more" aria-label="地图工具" onClick={() => setMapToolsOpen(true)} />} />
    {mapToolsOpen ? <Modal title="地图工具" onClose={() => setMapToolsOpen(false)}><div className="spatial-menu-actions"><Button icon="clock" onClick={()=>{openPanel('map-time');setMapToolsOpen(false);}}>时间轴</Button><Button icon="target" onClick={fitMap}>显示全部标记</Button><Button icon="minus" onClick={() => zoom(1 / 1.25)}>缩小地图</Button><Button icon="plus" onClick={() => zoom(1.25)}>放大地图</Button></div></Modal> : null}
    {eventListOpen && <Modal title="当前时间范围的事件" onClose={() => setEventListOpen(false)}><label className="spatial-search"><Icon name="search" size={20} /><input autoFocus placeholder="搜索事件、人物或地点" aria-label="搜索事件" value={query} onChange={(event) => setQuery(event.target.value)} />{query && <Button icon="close" variant="quiet" aria-label="清空事件搜索" onClick={() => setQuery('')} />}</label><div className="spatial-modal-list">{filteredEvents.filter((event) => `${event.name}${event.people.join('')}${event.place}`.includes(query)).map((event) => <button className="spatial-event-row" key={event.id} onClick={() => selectEvent(event)}><Icon name="clock" /><span><strong>{event.name}</strong><small>{event.year ? `${event.year}年` : '年代待考'} · {event.place}</small></span><Icon name="chevronRight" size={18} /></button>)}{!filteredEvents.some((event) => `${event.name}${event.people.join('')}${event.place}`.includes(query)) && <Empty icon="search" title="没有匹配的事件">调整搜索词或时间范围。</Empty>}</div></Modal>}
    {rangeEditor && <Modal title="精确时间范围" onClose={() => setRangeEditor(false)} footer={<><Button onClick={() => setRangeEditor(false)}>取消</Button><Button variant="primary" onClick={() => { const from = Number(rangeDraft[0]); const to = Number(rangeDraft[1]); if (!rangeDraft.every((value) => value.trim()) || !Number.isInteger(from) || !Number.isInteger(to) || from < MIN_YEAR || to > MAX_YEAR || from > to) { setRangeError('请输入 207–211 范围内的整数年份，起点不能晚于终点。'); return; } update({ timeRange: [from, to] }); setRangeEditor(false); }}>应用</Button></>}><p className="spatial-muted">这里编辑的仍是同一根时间轴上的两个端点。</p><div className="spatial-range-fields"><label>起点年份<input value={rangeDraft[0]} inputMode="numeric" onChange={(event) => setRangeDraft([event.target.value, rangeDraft[1]])} /></label><span>至</span><label>终点年份<input value={rangeDraft[1]} inputMode="numeric" onChange={(event) => setRangeDraft([rangeDraft[0], event.target.value])} /></label></div>{rangeError && <p className="spatial-error" role="alert">{rangeError}</p>}</Modal>}
    {optionsOpen && <Modal title="时间与地图选项" onClose={() => setOptionsOpen(false)}><div className="spatial-option-list"><label><input type="checkbox" checked={state.readingScope === 'current'} onChange={(event) => update({ readingScope: event.target.checked ? 'current' : 'book' })} /><span>只看当前原文相关事件<small>关系图谱同步使用这一范围</small></span></label><label><input type="checkbox" checked={showUndated} onChange={(event) => setShowUndated(event.target.checked)} /><span>保留年代待考的事件<small>未知坐标的事件只在清单中展示</small></span></label><Button icon="expand" onClick={() => { update({ timeRange: [MIN_YEAR, MAX_YEAR] }); setOptionsOpen(false); }}>显示全部时间</Button><Button icon="target" onClick={() => { fitMap(); setOptionsOpen(false); }}>地图适合全部标记</Button></div><p className="spatial-muted">从时间框标题拖动，松手可吸附四个角或下方中间。</p></Modal>}
    {inspectedPerson ? <Panel id="map-person" title={inspectedPerson} width={340} maximumHeight={490} avoidRects={[timelineFrame, mapToolbarFrame, mapNavigationFrame].filter(Boolean)} onFrameChange={receivePersonFrame} initial={{ x: Math.max(24, window.innerWidth - 364), y: 106 }} dock="top-right" className="spatial-person-panel">
      <label className="spatial-person-select">跟随人物<select aria-label="跟随人物" value={inspectedPerson || ''} onChange={(event) => setInspectedPerson(event.target.value || null)}><option value="">全部人物</option>{Object.keys(PEOPLE).map((person) => <option key={person}>{person}</option>)}</select></label>
      {inspectedPerson ? <><p className="spatial-type-tag">{inspectedPerson} · {cursor}年</p><p>{PEOPLE[inspectedPerson]}</p><h3>此时的线索</h3>{personEvents.length ? personEvents.map((event) => <button key={event.id} className="spatial-person-event" onClick={() => selectEvent(event)}><strong>{event.name}</strong><small>{(explicitPresenceIds[inspectedPerson] || []).includes(event.id) ? `示例出现记录 · ${event.place}` : '有参与记录，位置尚待核对'}</small></button>) : <p className="spatial-muted">此时没有已记录的行动或位置；不会沿用其他年份的位置。</p>}<p className="spatial-muted">拖动同一时间轴上的指针，卡片与地图一起更新。示例记录用于交互设计。</p></> : <p className="spatial-muted">选一位人物，沿时间查看他的事件、出现地点与出处。</p>}
    </Panel> : null}
  </div>;
}

function relationData(kind, scope) {
  if (kind !== 'history') return {
    nodes: [
      { id: 'r-matrix', title: '增广矩阵', subtitle: '概念', x: 60, y: 160, markdown: '将系数矩阵与常数列并在一起，得到增广矩阵 $[A\\mid b]$。\n\n判断线性方程组时，注意系数矩阵与增广矩阵的秩。' },
      { id: 'r-pivot', title: '主元与自由变量', subtitle: '概念', x: 410, y: -10, markdown: '阶梯形矩阵中每个非零行的首个非零元对应主元。非主元列对应自由变量。' },
      { id: 'r-solution', title: '解的存在与唯一性', subtitle: '定理', x: 410, y: 310, markdown: '若 $\\operatorname{rank}(A)=\\operatorname{rank}([A\\mid b])$，方程组有解。\n\n有解时，是否唯一还要看主元数是否等于未知量数。' },
    ], edges: [{ id: 'r-e1', from: 'r-matrix', to: 'r-pivot', label: '消元得到' }, { id: 'r-e2', from: 'r-pivot', to: 'r-solution', label: '帮助判断' }],
  };
  const events = scope === 'current' ? EVENTS.filter((event) => event.id === 'h-redcliff') : EVENTS.filter((event) => ['h-redcliff', 'h-jiangling'].includes(event.id));
  const names = [...new Set(events.flatMap((event) => event.people))];
  const personNodes = names.map((name, index) => ({ id: `person-${name}`, title: name, subtitle: '人物', x: index < 3 ? -80 : 650, y: (index % 3) * 190 - 50, markdown: PEOPLE[name] }));
  const eventNodes = events.map((event, index) => ({ id: event.id, title: event.name, subtitle: `${event.year}年 · 事件`, x: 285, y: index * 230 + 40, markdown: `${event.text}\n\n> ${event.quote}`, event }));
  return { nodes: [...eventNodes, ...personNodes], edges: events.flatMap((event) => event.people.map((name) => ({ id: `${name}-${event.id}`, from: `person-${name}`, to: event.id, label: '参与' }))) };
}

function edgeGeometry(from, to) {
  const right = to.x >= from.x;
  const a = { x: from.x + (right ? NODE_W : 0), y: from.y + NODE_H / 2 };
  const b = { x: to.x + (right ? 0 : NODE_W), y: to.y + NODE_H / 2 };
  const bend = Math.max(65, Math.abs(b.x - a.x) * 0.5);
  const sign = right ? 1 : -1;
  return { path: `M ${a.x} ${a.y} C ${a.x + bend * sign} ${a.y}, ${b.x - bend * sign} ${b.y}, ${b.x} ${b.y}`, x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
}

export function MindmapPage() { return <GraphPage editable />; }
export function RelationsPage() { return <GraphPage editable={false} />; }

function GraphPage({ editable }) {
  const { state, update, navigate, notify, confirm, book } = useApp();
  const viewportRef = useRef(null);
  const size = useViewport(viewportRef);
  const [browserFrame, receiveBrowserFrame] = useStableFrame();
  const [camera, setCamera] = useState({ x: 400, y: 260, scale: 1 });
  const cameraRef = useRef(camera);
  cameraRef.current = camera;
  const [selectedId, setSelectedId] = useState(null);
  const [query, setQuery] = useState('');
  const [draftPosition, setDraftPosition] = useState(null);
  const [connection, setConnection] = useState(null);
  const [preview, setPreview] = useState(null);
  const [menu, setMenu] = useState(null);
  const [nodePicker, setNodePicker] = useState(false);
  const [newTitle, setNewTitle] = useState('');
  const [renameEdge, setRenameEdge] = useState(null);
  const [edgeDraft, setEdgeDraft] = useState('');
  const [objectOpen, setObjectOpen] = useState(null);
  const [graphToolsOpen, setGraphToolsOpen] = useState(false);
  const [browserVisible, setBrowserVisible] = useState(true);
  const pointerRef = useRef(null);
  const suppressClick = useRef(0);
  const initialized = useRef('');
  const panelId = editable ? 'mindmap-nodes' : 'relation-nodes';
  const needsSeedLayout = editable && state.graphNodes.some((node) => node.bookId === book.id && isOriginalSeed(node));
  useLayoutEffect(() => {
    if (!needsSeedLayout) return;
    update((previous) => ({ ...previous, graphNodes: previous.graphNodes.map((node) => {
      if (node.bookId !== book.id || !isOriginalSeed(node)) return node;
      const seed = COMPACT_SEEDS[node.id];
      return { ...node, x: seed.next[0], y: seed.next[1], frostSeedLayout: true };
    }) }));
  }, [needsSeedLayout, book.id, update]);
  const docs = useMemo(() => state.documents.filter((document) => document.bookId === book.id && !document.deleted), [state.documents, book.id]);
  const docIndex = useMemo(() => new Map(docs.map((document) => [document.id, document])), [docs]);
  const derived = useMemo(() => relationData(book.id, state.readingScope), [book.id, state.readingScope]);
  const nodes = useMemo(() => editable ? state.graphNodes.filter((node) => node.bookId === book.id && docIndex.has(node.docId)).map((node) => { const document = docIndex.get(node.docId); return { ...node, title: document.title, subtitle: 'Markdown', markdown: document.markdown, source: document.source }; }) : derived.nodes, [editable, state.graphNodes, book.id, docIndex, derived]);
  const nodeIndex = useMemo(() => new Map(nodes.map((node) => [node.id, node])), [nodes]);
  const edges = useMemo(() => (editable ? state.graphEdges.filter((edge) => edge.bookId === book.id) : derived.edges).filter((edge) => nodeIndex.has(edge.from) && nodeIndex.has(edge.to)), [editable, state.graphEdges, book.id, derived, nodeIndex]);
  const displayNodes = draftPosition ? nodes.map((node) => node.id === draftPosition.id ? { ...node, x: draftPosition.x, y: draftPosition.y } : node) : nodes;
  const displayIndex = new Map(displayNodes.map((node) => [node.id, node]));
  const selected = nodeIndex.get(selectedId);
  const availableDocuments = docs.filter((document) => !nodes.some((node) => node.docId === document.id));
  const world = (event) => { const rect = viewportRef.current.getBoundingClientRect(); const current = cameraRef.current; return { x: current.x + (event.clientX - rect.left - size.width / 2) / current.scale, y: current.y + (event.clientY - rect.top - size.height / 2) / current.scale }; };
  const fit = useCallback(() => {
    if (!nodes.length) { setCamera({ x: 400, y: 260, scale: 1 }); return; }
    const left = Math.min(...nodes.map((node) => node.x)); const right = Math.max(...nodes.map((node) => node.x + NODE_W));
    const top = Math.min(...nodes.map((node) => node.y)); const bottom = Math.max(...nodes.map((node) => node.y + NODE_H));
    const availableWidth = Math.max(320, size.width - (size.width > 1050 && browserVisible ? 440 : 100));
    const scale = clamp(Math.min(availableWidth / (right - left + 100), (size.height - 210) / (bottom - top + 100)), 0.35, 1);
    setCamera({ x: (left + right) / 2 + (size.width > 1050 && browserVisible ? 180 / scale : 0), y: (top + bottom) / 2 - 25 / scale, scale });
  }, [nodes, size.width, size.height, browserVisible]);
  useEffect(() => {
    const identity = `${editable}-${book.id}`;
    if (initialized.current !== identity && size.ready && size.width > 0 && !needsSeedLayout) {
      const initialNode = editable
        ? nodes.find((node) => node.docId === state.selectedDocId) || nodes.find((node) => node.docId === (book.id === 'history' ? 'h-fire' : 'math-note')) || nodes[0]
        : nodes[0];
      if (size.width < 1050 && initialNode) {
        setCamera({ x: initialNode.x + NODE_W / 2, y: initialNode.y + NODE_H / 2, scale: 0.9 });
      } else fit();
      initialized.current = identity;
      setSelectedId(editable ? initialNode?.id || null : null);
      setQuery(''); setConnection(null); setMenu(null);
    }
  }, [editable, book.id, fit, size.width, size.ready, needsSeedLayout, nodes, state.selectedDocId]);
  useEffect(() => {
    const cancel = (event) => { if (event.key === 'Escape') { pointerRef.current = null; setDraftPosition(null); setConnection(null); setPreview(null); setMenu(null); } };
    const blur = () => { pointerRef.current = null; setDraftPosition(null); setConnection(null); setPreview(null); };
    window.addEventListener('keydown', cancel); window.addEventListener('blur', blur); window.addEventListener('resize', blur);
    return () => { window.removeEventListener('keydown', cancel); window.removeEventListener('blur', blur); window.removeEventListener('resize', blur); };
  }, []);
  useEffect(() => {
    if (!editable) return undefined;
    const create = () => setNodePicker(true);
    window.addEventListener('prototype-primary', create);
    return () => window.removeEventListener('prototype-primary', create);
  }, [editable]);
  useEffect(() => {
    const viewport = viewportRef.current?.querySelector('.spatial-graph-viewport');
    if (!viewport) return undefined;
    const wheel = (event) => event.preventDefault();
    viewport.addEventListener('wheel', wheel, { passive: false });
    return () => viewport.removeEventListener('wheel', wheel);
  }, []);
  const zoom = (factor, point = { x: size.width / 2, y: size.height / 2 }) => setCamera((previous) => {
    const scale = clamp(previous.scale * factor, 0.2, 2.5);
    const at = { x: previous.x + (point.x - size.width / 2) / previous.scale, y: previous.y + (point.y - size.height / 2) / previous.scale };
    return { x: at.x - (point.x - size.width / 2) / scale, y: at.y - (point.y - size.height / 2) / scale, scale };
  });
  const focusNode = (node) => { setSelectedId(node.id); setCamera((previous) => ({ ...previous, x: node.x + NODE_W / 2 + (size.width > 1050 ? 180 / previous.scale : 0), y: node.y + NODE_H / 2 })); openPanel(panelId); };
  const openNode = (node) => { if (editable) navigate('notes', { selectedDocId: node.docId }); else setObjectOpen(node); };
  const connect = (from, to) => {
    if (!editable || from === to) { setConnection(null); setPreview(null); return; }
    if (edges.some((edge) => edge.from === from && edge.to === to)) { notify('这两个节点之间已有同向连线。'); setConnection(null); setPreview(null); return; }
    update((previous) => ({ ...previous, graphEdges: [...previous.graphEdges, { id: `edge-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`, bookId: book.id, from, to, label: '延伸' }] }));
    setConnection(null); setPreview(null); notify('已添加连线。双击线上的名称可以修改。');
  };
  const targetAt = (point, sourceId) => nodes.find((node) => node.id !== sourceId && point.x >= node.x - 12 && point.x <= node.x + NODE_W + 12 && point.y >= node.y - 12 && point.y <= node.y + NODE_H + 12);
  const movePointer = (event) => {
    const pointer = pointerRef.current;
    if (pointer) {
      const dx = event.clientX - pointer.startX; const dy = event.clientY - pointer.startY;
      if (Math.hypot(dx, dy) > 4) pointer.moved = true;
      if (pointer.type === 'node' && pointer.moved) setDraftPosition({ id: pointer.id, x: pointer.x + dx / pointer.scale, y: pointer.y + dy / pointer.scale });
      if (pointer.type === 'pan') setCamera({ ...pointer.camera, x: pointer.camera.x - dx / pointer.scale, y: pointer.camera.y - dy / pointer.scale });
      if (pointer.type === 'connection') { const point = world(event); setPreview({ ...point, target: targetAt(point, pointer.id)?.id }); }
    } else if (connection) { const point = world(event); setPreview({ ...point, target: targetAt(point, connection)?.id }); }
  };
  const finishPointer = (event) => {
    const pointer = pointerRef.current; if (!pointer) return;
    pointerRef.current = null;
    if (pointer.moved) suppressClick.current = Date.now() + 250;
    if (pointer.type === 'node' && pointer.moved) {
      const x = pointer.x + (event.clientX - pointer.startX) / pointer.scale;
      const y = pointer.y + (event.clientY - pointer.startY) / pointer.scale;
      update((previous) => ({ ...previous, graphNodes: previous.graphNodes.map((node) => node.id === pointer.id ? { ...node, x, y } : node) }));
    }
    if (pointer.type === 'connection' && pointer.moved) { const target = targetAt(world(event), pointer.id); if (target) connect(pointer.id, target.id); else { setConnection(null); setPreview(null); } }
    setDraftPosition(null);
  };
  const removeNode = async (node) => {
    setMenu(null);
    if (!await confirm({ title: '移除节点？', body: `“${node.title}”的 Markdown 文档会保留。这里只移除该节点及其连线，以后可从“新建节点”重新加入。`, confirmLabel: '移除节点' })) return;
    update((previous) => ({ ...previous, graphNodes: previous.graphNodes.filter((item) => item.id !== node.id), graphEdges: previous.graphEdges.filter((edge) => edge.from !== node.id && edge.to !== node.id) }));
    if (selectedId === node.id) setSelectedId(null); notify('已移除节点，文档仍在“我的笔记”中。');
  };
  const trashDocument = async (node) => {
    setMenu(null);
    if (!await confirm({ title: '将文档移入回收站？', body: `“${node.title}”及引用它的节点会暂时隐藏。恢复文档后，原有节点位置和连线一起恢复。`, confirmLabel: '移入回收站', danger: true })) return;
    update((previous) => ({ ...previous, documents: previous.documents.map((document) => document.id === node.docId ? { ...document, deleted: true } : document) }));
    setSelectedId(null); notify('已移入回收站，可从导航中的回收站恢复。');
  };
  const addDocumentNode = (documentId) => {
    const id = `n-${documentId}-${Date.now()}`;
    update((previous) => ({ ...previous, graphNodes: [...previous.graphNodes, { id, bookId: book.id, docId: documentId, x: camera.x - NODE_W / 2, y: camera.y - NODE_H / 2 }] }));
    setSelectedId(id); setNodePicker(false); openPanel(panelId); notify('已加入导图，原文档保持不变。');
  };
  const createDocument = () => {
    if (!newTitle.trim()) return;
    const id = `doc-${Date.now()}`; const nodeId = `n-${id}`;
    update((previous) => ({ ...previous, documents: [...previous.documents, { id, bookId: book.id, title: newTitle.trim(), markdown: `# ${newTitle.trim()}\n\n写下此刻的理解。`, deleted: false, source: null, updatedAt: new Date().toISOString() }], graphNodes: [...previous.graphNodes, { id: nodeId, bookId: book.id, docId: id, x: camera.x - NODE_W / 2, y: camera.y - NODE_H / 2 }] }));
    setNewTitle(''); setNodePicker(false); setSelectedId(nodeId); notify('已建立示例 Markdown 文档与节点，双击可编辑。');
  };
  const selectedMarkdown = selected ? (editable ? docIndex.get(selected.docId)?.markdown : selected.markdown) : '';
  const previewHeading = selectedMarkdown?.match(/^# ([^\n]+)/)?.[1] || selected?.title;
  const selectedPreview = selectedMarkdown?.replace(/^# [^\n]+\n?/, '').trimStart();
  const statusText = connection ? `从“${nodeIndex.get(connection)?.title}”连线 · 点击目标节点，Esc 取消`
    : '';
  const zoomButtons = <><Button icon="minus" aria-label="缩小画布" onClick={() => zoom(1 / 1.2)} /><button className="spatial-zoom-value" title="恢复 100% 缩放" onClick={() => zoom(1 / camera.scale)}>{Math.round(camera.scale * 100)}%</button><Button icon="plus" aria-label="放大画布" onClick={() => zoom(1.2)} /></>;
  const moreTools = <Button icon="more" aria-label="画布工具与状态" onClick={() => setGraphToolsOpen(true)} />;
  const scopeTitle = state.readingScope === 'current' ? '当前原文' : '全书';
  const nextScopeTitle = state.readingScope === 'current' ? '全书' : '当前原文';
  const toggleScope = () => update({ readingScope: state.readingScope === 'current' ? 'book' : 'current' });
  return <div className="spatial-page spatial-graph-page" ref={viewportRef}>
    <div className="spatial-graph-viewport" aria-label={editable ? '无限文档导图，可拖动节点或空白画布' : '只读关系图谱，可平移和缩放'} style={{ backgroundSize: `${26 * camera.scale}px ${26 * camera.scale}px`, backgroundPosition: `${size.width / 2 - camera.x * camera.scale}px ${size.height / 2 - camera.y * camera.scale}px` }} onPointerDown={(event) => {
      if (event.button !== 0 || event.target.closest('.spatial-graph-node,.spatial-edge-label,button,input')) return;
      setMenu(null); event.currentTarget.setPointerCapture(event.pointerId); pointerRef.current = { type: 'pan', startX: event.clientX, startY: event.clientY, camera: { ...camera }, scale: camera.scale, moved: false };
    }} onPointerMove={movePointer} onPointerUp={finishPointer} onPointerCancel={() => { pointerRef.current = null; setDraftPosition(null); setConnection(null); setPreview(null); }} onClick={(event) => { if (event.target === event.currentTarget && Date.now() > suppressClick.current) { setSelectedId(null); setConnection(null); setPreview(null); setMenu(null); } }} onContextMenu={(event) => { if (event.target.closest('.spatial-graph-node,.spatial-edge-label')) return; event.preventDefault(); if (editable) { const rect = viewportRef.current.getBoundingClientRect(); setMenu({ x: clamp(event.clientX - rect.left, 12, size.width - 252), y: clamp(event.clientY - rect.top, 90, size.height - 120), nodeId: null }); } }} onWheel={(event) => {
      if (event.ctrlKey || event.metaKey) { const rect = event.currentTarget.getBoundingClientRect(); zoom(event.deltaY > 0 ? 0.94 : 1.06, { x: event.clientX - rect.left, y: event.clientY - rect.top }); }
      else setCamera((previous) => ({ ...previous, x: previous.x + event.deltaX / previous.scale, y: previous.y + event.deltaY / previous.scale }));
    }}>
      <div className="spatial-graph-world" style={{ transform: `translate(${size.width / 2 - camera.x * camera.scale}px,${size.height / 2 - camera.y * camera.scale}px) scale(${camera.scale})` }}>
        <svg className="spatial-graph-edges" width="1" height="1" aria-hidden="true"><defs><marker id={`arrow-${editable ? 'mind' : 'rel'}`} markerWidth="7" markerHeight="7" refX="6" refY="3.5" orient="auto"><path d="M0,0 L7,3.5 L0,7 Z" /></marker></defs>{edges.map((edge) => { const geometry = edgeGeometry(displayIndex.get(edge.from), displayIndex.get(edge.to)); return <path key={edge.id} d={geometry.path} markerEnd={`url(#arrow-${editable ? 'mind' : 'rel'})`} />; })}{connection && preview && displayIndex.has(connection) && (() => { const source = displayIndex.get(connection); const start = { x: source.x + NODE_W, y: source.y + NODE_H / 2 }; return <path className="spatial-preview-edge" d={`M ${start.x} ${start.y} C ${start.x + 90} ${start.y}, ${preview.x - 90} ${preview.y}, ${preview.x} ${preview.y}`} />; })()}</svg>
        {edges.map((edge) => { const geometry = edgeGeometry(displayIndex.get(edge.from), displayIndex.get(edge.to)); return <button className={`spatial-edge-label ${editable ? 'is-editable' : ''}`} style={{ left: geometry.x, top: geometry.y }} key={edge.id} aria-label={`${edge.label}${editable ? '，双击修改关系名称' : '，派生关系'}`} onDoubleClick={() => { if (editable) { setRenameEdge(edge); setEdgeDraft(edge.label); } }} onContextMenu={(event) => { if (!editable) return; event.preventDefault(); const rect = viewportRef.current.getBoundingClientRect(); setMenu({ x: clamp(event.clientX - rect.left, 12, size.width - 252), y: clamp(event.clientY - rect.top, 90, size.height - 145), edgeId: edge.id }); }}>{edge.label}</button>; })}
        {displayNodes.map((node) => <div className={`spatial-graph-node ${selectedId === node.id ? 'is-selected' : ''} ${preview?.target === node.id ? 'is-target' : ''} ${draftPosition?.id === node.id ? 'is-dragging' : ''}`} key={node.id} style={{ left: node.x, top: node.y, width: NODE_W, height: NODE_H }} tabIndex="0" role="button" aria-label={`${node.title}，${node.subtitle}，${editable ? '单击预览，双击打开，拖动移动' : '单击预览，双击查看详情'}`} onPointerDown={(event) => {
          if (event.button !== 0 || event.target.closest('.spatial-node-port')) return;
          event.stopPropagation(); setMenu(null); setSelectedId(node.id); openPanel(panelId);
          if (!editable || connection) return;
          event.currentTarget.setPointerCapture(event.pointerId); pointerRef.current = { type: 'node', id: node.id, startX: event.clientX, startY: event.clientY, x: node.x, y: node.y, scale: camera.scale, moved: false };
        }} onClick={(event) => { event.stopPropagation(); if (Date.now() < suppressClick.current) return; if (connection) { connect(connection, node.id); return; } setSelectedId(node.id); openPanel(panelId); }} onDoubleClick={(event) => { event.stopPropagation(); if (Date.now() > suppressClick.current && !connection) openNode(node); }} onContextMenu={(event) => { event.preventDefault(); event.stopPropagation(); setSelectedId(node.id); if (!editable) { setObjectOpen(node); return; } const rect = viewportRef.current.getBoundingClientRect(); setMenu({ x: clamp(event.clientX - rect.left, 12, size.width - 252), y: clamp(event.clientY - rect.top, 90, size.height - 275), nodeId: node.id }); }} onKeyDown={(event) => {
          if (event.target !== event.currentTarget) return;
          if (event.key === 'Enter') { event.preventDefault(); if (connection) connect(connection, node.id); else openNode(node); }
          if (event.key === ' ') { event.preventDefault(); setSelectedId(node.id); openPanel(panelId); }
          if (editable && event.key === 'Delete') { event.preventDefault(); removeNode(node); }
        }}><span className="spatial-node-file"><Icon name={editable ? 'file' : node.subtitle.includes('人物') ? 'cards' : 'relations'} size={31} /></span><span className="spatial-node-copy"><strong>{node.title}</strong><small>{editable ? textSummary(node.markdown) : node.subtitle}</small></span>
          {editable && ['left', 'right'].map((side) => <button key={side} className={`spatial-node-port spatial-port-${side}`} aria-label={`从“${node.title}”${side === 'left' ? '左' : '右'}连接点连线`} title="点击后选择目标，或按住拖出连线" onPointerDown={(event) => {
            event.stopPropagation(); event.preventDefault();
            if (connection && connection !== node.id) { connect(connection, node.id); return; }
            setConnection(node.id); setSelectedId(node.id); setPreview(null); event.currentTarget.setPointerCapture(event.pointerId);
            pointerRef.current = { type: 'connection', id: node.id, startX: event.clientX, startY: event.clientY, scale: camera.scale, moved: false };
          }} onClick={(event) => event.stopPropagation()} onKeyDown={(event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); event.stopPropagation(); if (connection && connection !== node.id) connect(connection, node.id); else { setConnection(node.id); setSelectedId(node.id); } } }} />)}
        </div>)}
      </div>
    </div>
    <Panel toolbarRestore id={panelId} title={editable ? '节点' : '对象与关系'} width={370} dock="right" className="spatial-node-panel" onFrameChange={receiveBrowserFrame} onVisibilityChange={setBrowserVisible} autoCloseBelow={1050}>
      <label className="spatial-search"><Icon name="search" size={20} /><input placeholder="搜索节点…" aria-label="搜索节点" value={query} onChange={(event) => setQuery(event.target.value)} />{query && <Button icon="close" variant="quiet" aria-label="清空节点搜索" onClick={() => setQuery('')} />}</label>
      <div className="spatial-node-list">{nodes.filter((node) => `${node.title}${node.markdown}`.toLowerCase().includes(query.toLowerCase())).map((node) => <button className={`spatial-node-row ${selectedId === node.id ? 'is-selected' : ''}`} key={node.id} onClick={() => focusNode(node)} onDoubleClick={() => openNode(node)}><Icon name={editable ? 'file' : 'cards'} size={25} /><span><strong>{node.title}</strong><small>{editable ? textSummary(node.markdown) : node.subtitle}</small></span></button>)}{!nodes.some((node) => `${node.title}${node.markdown}`.toLowerCase().includes(query.toLowerCase())) && <p className="spatial-muted spatial-no-results">{query ? '没有匹配的节点' : '当前范围还没有节点'}</p>}</div>
      <section className="spatial-node-preview">{selected ? <><h3>{previewHeading}</h3><Markdown text={selectedPreview || '这篇文档还没有正文。'} /><p className="spatial-interaction-caption">单击预览 · 双击{editable ? '打开文档' : '查看详情'}</p></> : <><h3>{editable ? '每一篇理解，都可以连接' : '从原文看见关联'}</h3><p className="spatial-muted">单击节点预览，双击打开。{editable ? '拖动节点移动位置，从边缘圆点拖出连线。' : '这是 AI 分析产生的只读关系，浏览不会改写分析。'}</p></>}</section>
    </Panel>
    <SpatialChrome viewport={size} obstacles={[browserFrame].filter(Boolean)} statusText={statusText}
      full={<>{zoomButtons}<Button icon="sidebar" aria-label="节点列表" title="节点列表" className={browserVisible?'is-selected':''} onClick={()=>window.dispatchEvent(new CustomEvent(browserVisible?'prototype-panel-close':'prototype-panel-open',{detail:{id:panelId}}))}/><span className="spatial-tool-divider" /><Button icon="expand" aria-label="显示全部节点" onClick={fit} />{editable ? <><span className="spatial-tool-divider" /><Button icon="plus" onClick={() => setNodePicker(true)}>新建节点</Button></> : <Button icon="filter" aria-label={`当前范围${scopeTitle}，切换到${nextScopeTitle}`} title={`切换到${nextScopeTitle}`} onClick={toggleScope}>{scopeTitle}</Button>}{moreTools}</>}
      compact={<>{zoomButtons}<Button icon="sidebar" aria-label="节点列表" onClick={()=>openPanel(panelId)}/>{moreTools}</>} menu={moreTools}
      status={connection ? <div className="spatial-status-content" role="status"><span>{statusText}</span><Button icon="close" variant="quiet" aria-label="取消连线" onClick={() => { setConnection(null); setPreview(null); }} /></div> : null} />
    {graphToolsOpen ? <Modal title="画布工具与状态" onClose={() => setGraphToolsOpen(false)}><p className="spatial-muted">{statusText||`${nodes.length} 个节点 · ${edges.length} 条连线`}</p><div className="spatial-menu-actions"><Button icon="sidebar" onClick={()=>{openPanel(panelId);setGraphToolsOpen(false);}}>节点列表</Button><Button icon="minus" onClick={() => zoom(1 / 1.2)}>缩小画布</Button><Button icon="refresh" onClick={() => zoom(1 / camera.scale)}>恢复100%</Button><Button icon="plus" onClick={() => zoom(1.2)}>放大画布</Button><Button icon="expand" onClick={fit}>显示全部节点</Button>{editable ? <Button icon="plus" onClick={() => { setGraphToolsOpen(false); setNodePicker(true); }}>新建节点</Button> : <Button icon="filter" onClick={() => { toggleScope(); setGraphToolsOpen(false); }}>范围：{scopeTitle} · 切换到{nextScopeTitle}</Button>}{connection ? <Button icon="close" onClick={() => { setConnection(null); setPreview(null); }}>取消连线</Button> : null}</div></Modal> : null}
    {nodes.length === 0 && <div className="spatial-canvas-empty"><Empty icon={editable ? 'mindmap' : 'relations'} title={editable ? '从第一篇理解开始' : '当前范围还没有关系'} action={editable ? <Button icon="plus" variant="primary" onClick={() => setNodePicker(true)}>创建第一篇笔记</Button> : <Button onClick={() => update({ readingScope: 'book' })}>查看全书范围</Button>}>{editable ? '新建笔记，或将已有 Markdown 文档加入导图。' : '返回原文继续阅读，已保存的数据不会因为筛选消失。'}</Empty></div>}
    {menu && <><button className="spatial-context-dismiss" aria-label="关闭图谱菜单" onClick={() => setMenu(null)} /><div className="spatial-context-menu" role="menu" style={{ left: menu.x, top: menu.y }}>
      {menu.edgeId ? <><button role="menuitem" onClick={() => { const edge = edges.find((item) => item.id === menu.edgeId); setRenameEdge(edge); setEdgeDraft(edge.label); setMenu(null); }}><Icon name="edit" size={18} />修改关系名称</button><button role="menuitem" onClick={() => { update((previous) => ({ ...previous, graphEdges: previous.graphEdges.filter((edge) => edge.id !== menu.edgeId) })); setMenu(null); notify('已移除连线，节点与文档保留。'); }}><Icon name="minus" size={18} />移除连线</button></> : menu.nodeId ? <><button role="menuitem" onClick={() => { openNode(nodeIndex.get(menu.nodeId)); setMenu(null); }}><Icon name="file" size={18} />打开文档</button><button role="menuitem" onClick={() => { setConnection(menu.nodeId); setPreview(null); setMenu(null); }}><Icon name="link" size={18} />从这里连线</button>{connection && connection !== menu.nodeId && <button role="menuitem" onClick={() => { connect(connection, menu.nodeId); setMenu(null); }}><Icon name="check" size={18} />连接到这里</button>}<hr /><button role="menuitem" onClick={() => removeNode(nodeIndex.get(menu.nodeId))}><Icon name="minus" size={18} />移除节点，保留文档</button><button role="menuitem" className="spatial-danger-text" onClick={() => trashDocument(nodeIndex.get(menu.nodeId))}><Icon name="trash" size={18} />将文档移入回收站</button></> : <button role="menuitem" onClick={() => { setNodePicker(true); setMenu(null); }}><Icon name="plus" size={18} />新建节点</button>}
    </div></>}
    {nodePicker && <Modal title="新建节点" onClose={() => setNodePicker(false)}><p className="spatial-muted">节点引用 Markdown 文档，移动或移除节点不会改写正文。</p><form className="spatial-new-node" onSubmit={(event) => { event.preventDefault(); createDocument(); }}><label>创建一篇笔记<input autoFocus value={newTitle} onChange={(event) => setNewTitle(event.target.value)} placeholder="给此刻的理解起个名字" /></label><Button icon="plus" variant="primary" disabled={!newTitle.trim()} type="submit">创建</Button></form><h3 className="spatial-section-title">加入已有文档</h3><div className="spatial-modal-list">{availableDocuments.map((document) => <button className="spatial-event-row" key={document.id} onClick={() => addDocumentNode(document.id)}><Icon name="file" /><span><strong>{document.title}</strong><small>{textSummary(document.markdown)}</small></span><Icon name="plus" size={18} /></button>)}{availableDocuments.length === 0 && <p className="spatial-muted">当前文档均已加入导图。移除节点后可在这里重新加入。</p>}</div></Modal>}
    {renameEdge && <Modal title="关系名称" onClose={() => setRenameEdge(null)} footer={<><Button onClick={() => setRenameEdge(null)}>取消</Button><Button variant="primary" disabled={!edgeDraft.trim()} onClick={() => { update((previous) => ({ ...previous, graphEdges: previous.graphEdges.map((edge) => edge.id === renameEdge.id ? { ...edge, label: edgeDraft.trim() } : edge) })); setRenameEdge(null); notify('已更新关系名称。'); }}>保存</Button></>}><label className="spatial-field">这条连线表示什么？<input autoFocus maxLength={40} value={edgeDraft} onChange={(event) => setEdgeDraft(event.target.value)} onKeyDown={(event) => { if (event.key === 'Enter' && edgeDraft.trim()) { update((previous) => ({ ...previous, graphEdges: previous.graphEdges.map((edge) => edge.id === renameEdge.id ? { ...edge, label: edgeDraft.trim() } : edge) })); setRenameEdge(null); } }} /></label></Modal>}
    {objectOpen && <Modal title={objectOpen.title} onClose={() => setObjectOpen(null)}><span className="spatial-type-tag">{objectOpen.subtitle} · AI 分析要素</span><Markdown text={objectOpen.markdown} />{objectOpen.event && <div className="spatial-object-actions"><Button icon="map" onClick={() => { update({ selectedEventId: objectOpen.event.id }); setObjectOpen(null); navigate('map'); }}>在时间与地图查看</Button><Button icon="book" onClick={() => { const event = objectOpen.event; setObjectOpen(null); navigate('reader', { page: event.page, source: event.source }); }}>原文依据</Button></div>}</Modal>}
  </div>;
}
