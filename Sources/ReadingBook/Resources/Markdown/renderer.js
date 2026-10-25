/* ReadingBook's trusted offline renderer. Input is Markdown data, never executable HTML. */
(function (global) {
  'use strict';
  const md = global.markdownit({ html: false, linkify: true, typographer: false, breaks: false });
  const escape = md.utils.escapeHtml;
  const environments = '(?:equation|align|alignat|gather|multline|aligned|alignedat|gathered|split|cases|matrix|pmatrix|bmatrix|Bmatrix|vmatrix|Vmatrix|smallmatrix|CD)\\*?';
  const beginEnvironment = new RegExp('^\\\\begin\\{(' + environments + ')\\}');
  let currentRevision = 0;
  let selectionEnabled = false;
  let currentSource = '';
  let sourceDecorations = [];
  let appliedDecorations = new Map();
  let decorationsDeferred = false;
  let sourcePress = null;

  function escapedAt(source, position) {
    let backslashes = 0;
    while (position > 0 && source[--position] === '\\') backslashes++;
    return backslashes % 2 === 1;
  }
  function opening(source, position) {
    const rest = source.slice(position);
    if (rest.startsWith('$$')) return { left: '$$', right: '$$', display: true };
    if (rest.startsWith('\\[')) return { left: '\\[', right: '\\]', display: true };
    if (rest.startsWith('\\(')) return { left: '\\(', right: '\\)', display: false };
    const environment = rest.match(beginEnvironment);
    if (environment) return { left: environment[0], right: '\\end{' + environment[1] + '}', display: true, keep: true };
    if (rest[0] === '$' && rest[1] && !/\s/.test(rest[1])) return { left: '$', right: '$', display: false };
    return null;
  }
  function closing(source, start, delimiter, limit) {
    let position = start;
    while ((position = source.indexOf(delimiter.right, position)) !== -1 && position < limit) {
      if (!escapedAt(source, position) && !(delimiter.right === '$' && (/\s/.test(source[position - 1] || '') || /\d/.test(source[position + 1] || '')))) return position;
      position += delimiter.right.length;
    }
    return -1;
  }
  function mathHTML(source, display, original) {
    try {
      if (source.length > 24_000) throw new Error('公式超过 24,000 字符，已保留原式');
      if (/\\(?:includegraphics|href|url|htmlClass|htmlStyle|htmlId|htmlData)\b/.test(source)) throw new Error('此公式含外部资源或 HTML 命令；安全阅读模式保留原式');
      const output = global.katex.renderToString(source, {
        displayMode: display, throwOnError: true, output: 'htmlAndMathml', trust: false,
        strict: 'ignore', maxExpand: 1_000, maxSize: 20, macros: Object.create(null)
      });
      return '<' + (display ? 'div class="math-display" tabindex="0" role="region" aria-label="公式，可横向滚动"' : 'span class="math-inline"') + '>' + output + '</' + (display ? 'div' : 'span') + '>';
    } catch (error) {
      const message = String(error.message || error).replace(/^KaTeX parse error:\s*/, '').slice(0, 260);
      return '<' + (display ? 'div' : 'span') + ' class="math-error"><strong>公式未能排版：' + escape(message) + '</strong><code>' + escape(original) + '</code></' + (display ? 'div' : 'span') + '>';
    }
  }
  md.inline.ruler.before('escape', 'readingbook_math', function (state, silent) {
    const start = state.pos;
    const delimiter = opening(state.src, start);
    if (!delimiter) return false;
    const end = closing(state.src, start + delimiter.left.length, delimiter, state.posMax);
    if (end < 0) return false;
    if (!silent) {
      const token = state.push('readingbook_math', '', 0);
      token.content = delimiter.keep ? state.src.slice(start, end + delimiter.right.length) : state.src.slice(start + delimiter.left.length, end);
      token.meta = { display: delimiter.display, original: state.src.slice(start, end + delimiter.right.length) };
    }
    state.pos = end + delimiter.right.length;
    return true;
  });
  md.renderer.rules.readingbook_math = (tokens, index) => {
    const token = tokens[index], html = mathHTML(token.content, token.meta.display, token.meta.original);
    return sourceBlockHTML(html, token.meta?.readingbookBlock);
  };
  md.block.ruler.before('fence', 'readingbook_math_block', function (state, startLine, endLine, silent) {
    const start = state.bMarks[startLine] + state.tShift[startLine];
    if (state.sCount[startLine] - state.blkIndent >= 4) return false;
    const delimiter = opening(state.src, start);
    if (!delimiter || !delimiter.display) return false;
    const end = closing(state.src, start + delimiter.left.length, delimiter, state.eMarks[endLine - 1]);
    if (end < 0) return false;
    let finalLine = startLine;
    while (finalLine + 1 < endLine && state.bMarks[finalLine + 1] <= end) finalLine++;
    if (state.src.slice(end + delimiter.right.length, state.eMarks[finalLine]).trim()) return false;
    if (silent) return true;
    const token = state.push('readingbook_math', '', 0);
    token.block = true;
    token.map = [startLine, finalLine + 1];
    token.content = delimiter.keep ? state.src.slice(start, end + delimiter.right.length) : state.src.slice(start + delimiter.left.length, end);
    token.meta = { display: true, original: state.src.slice(start, end + delimiter.right.length) };
    state.line = finalLine + 1;
    return true;
  }, { alt: ['paragraph', 'reference', 'blockquote', 'list'] });

  md.validateLink = function (href) {
    const value = String(href).trim();
    return value.startsWith('#') || /^(https?:|mailto:|readingbook:)/i.test(value) || (!/^[a-z][a-z0-9+.-]*:/i.test(value) && !value.startsWith('//'));
  };
  const defaultLink = md.renderer.rules.link_open || ((tokens, index, options, env, renderer) => renderer.renderToken(tokens, index, options));
  md.renderer.rules.link_open = function (tokens, index, options, env, renderer) {
    const token = tokens[index];
    const href = token.attrGet('href') || '';
    if (!/^(https?:|mailto:|readingbook:|#)/i.test(href)) {
      // A relative document link is visible text, not permission to open a file URL.
      token.attrSet('href', '#'); token.attrSet('data-unavailable-link', 'true');
      token.attrSet('title', '请使用书籍内部引用；不直接打开本机相对路径');
    }
    token.attrSet('rel', 'noreferrer noopener');
    return defaultLink(tokens, index, options, env, renderer);
  };
  function relativeImage(source) {
    try {
      const path = decodeURIComponent(String(source).split(/[?#]/)[0]);
      if (!path || /^[a-z][a-z0-9+.-]*:/i.test(path) || path.startsWith('/') || /[\\\x00-\x1f\x7f]/.test(path)) return null;
      const parts = path.split('/');
      if (parts.some(part => !part || part === '.' || part === '..')) return null;
      if (!/\.(png|jpe?g|gif|webp|heic|avif)$/i.test(path)) return null;
      return parts.map(encodeURIComponent).join('/');
    } catch (_) { return null; }
  }
  md.renderer.rules.image = function (tokens, index, options, env) {
    const token = tokens[index], source = token.attrGet('src') || '';
    const description = md.renderer.renderInlineAsText(token.children || [], options, env) || '图片';
    const path = relativeImage(source);
    if (!env.allowImages || !path) return '<span class="image-placeholder" role="note">图片：' + escape(description) + ' · ' + (!path ? '外部或未知图片路径，未加载' : '尚未授权本地图片目录') + '</span>';
    return '<img src="readingbook-renderer://image/' + path + '?v=' + env.revision + '" alt="' + escape(description) + '" loading="eager" decoding="async">';
  };
  md.renderer.rules.table_open = (tokens, index) => '<div class="table-scroll" tabindex="0" role="region" aria-label="表格，可横向滚动"' + sourceBlockAttributes(tokens[index].meta?.readingbookBlock) + '><table>\n';
  md.renderer.rules.table_close = () => '</table></div>\n';
  const defaultHeading = md.renderer.rules.heading_open || ((tokens, index, options, env, renderer) => renderer.renderToken(tokens, index, options));
  md.renderer.rules.heading_open = function (tokens, index, options, env, renderer) {
    const title = tokens[index + 1]?.content || 'heading';
    const stem = title.toLowerCase().replace(/[^\p{L}\p{N} _-]/gu, '').trim().replace(/\s+/g, '-') || 'heading';
    const count = env.headings[stem] || 0; env.headings[stem] = count + 1;
    tokens[index].attrSet('id', stem + (count ? '-' + count : ''));
    return defaultHeading(tokens, index, options, env, renderer);
  };

  // Keep a source map only when every consumed character is accounted for.
  // Transformed escapes/entities, links, code and math never become invented
  // word locations. Their block still has an honest paragraph-level fallback.
  const defaultText = md.renderer.rules.text || ((tokens, index) => escape(tokens[index].content));
  md.renderer.rules.text = function (tokens, index, options, env, renderer) {
    const token = tokens[index], range = token.meta?.readingbookSource;
    const html = defaultText(tokens, index, options, env, renderer);
    if (!range || !token.content) return html;
    return '<span data-source-start="' + range[0] + '" data-source-end="' + range[1] + '">' + html + '</span>';
  };
  function sourceBlockAttributes(range) {
    return range ? ' data-source-block-start="' + range[0] + '" data-source-block-end="' + range[1] + '"' : '';
  }
  function sourceBlockHTML(html, range) {
    return range ? '<div class="source-block"' + sourceBlockAttributes(range) + '>' + html + '</div>' : html;
  }
  for (const type of ['fence', 'code_block']) {
    const original = md.renderer.rules[type];
    md.renderer.rules[type] = (tokens, index, options, env, renderer) => sourceBlockHTML(original(tokens, index, options, env, renderer), tokens[index].meta?.readingbookBlock);
  }
  function prepareSourceMap(tokens, source, enabled) {
    if (!enabled || /\0|\r(?!\n)/.test(source)) return;
    const offsets = [0];
    for (let i = 0; i < source.length; i++) if (source[i] === '\n') offsets.push(i + 1);
    offsets.push(source.length);
    for (let index = 0; index < tokens.length; index++) {
      const token = tokens[index];
      if (token.block && token.map && ['fence', 'code_block', 'readingbook_math', 'table_open'].includes(token.type)) {
        token.meta = Object.assign({}, token.meta, { readingbookBlock: [offsets[token.map[0]] ?? 0, offsets[token.map[1]] ?? source.length] });
      }
      if (token.map && token.nesting === 1 && ['paragraph_open', 'heading_open', 'blockquote_open', 'list_item_open'].includes(token.type)) {
        token.attrSet('data-source-block-start', String(offsets[token.map[0]] ?? 0));
        token.attrSet('data-source-block-end', String(offsets[token.map[1]] ?? source.length));
      }
      if (token.type !== 'inline' || !token.map || !token.children) continue;
      const start = offsets[token.map[0]] ?? 0, end = offsets[token.map[1]] ?? source.length;
      const block = source.slice(start, end), relative = block.indexOf(token.content);
      if (relative < 0 || block.indexOf(token.content, relative + 1) >= 0) continue;
      let cursor = 0, valid = true;
      const mapped = [];
      for (const child of token.children) {
        let raw;
        if (child.type === 'text') {
          raw = child.content;
          mapped.push([child, start + relative + cursor, start + relative + cursor + raw.length]);
        } else if (/^(em|strong|s)_(open|close)$/.test(child.type)) raw = child.markup;
        else if (child.type === 'softbreak') raw = '\n';
        else if (child.type === 'code_inline') raw = child.markup + child.content + child.markup;
        else if (child.type === 'readingbook_math') raw = child.meta.original;
        else { valid = false; break; }
        if (token.content.slice(cursor, cursor + raw.length) !== raw) { valid = false; break; }
        cursor += raw.length;
      }
      if (valid && cursor === token.content.length) for (const [child, from, to] of mapped) {
        child.meta = Object.assign({}, child.meta, { readingbookSource: [from, to] });
      }
    }
  }

  function renderHTML(markdown, options) {
    const settings = options || {};
    const source = String(markdown || '');
    if (source.length > 2_000_000) return '<p class="renderer-note">此段内容过长，请按章节查看；原文未被截断保存。</p>';
    if (settings.plainText) {
      const attributes = settings.sourceText === source && !source.includes('\0') ? ' data-source-start="0" data-source-end="' + source.length + '" data-source-block-start="0" data-source-block-end="' + source.length + '"' : '';
      return '<div class="source-plain"' + attributes + '>' + escape(source).replace(/\r/g, '&#13;') + '</div>';
    }
    const env = { allowImages: !!settings.allowImages, revision: Number(settings.revision) || 0, headings: Object.create(null) };
    const tokens = md.parse(source, env);
    prepareSourceMap(tokens, source, typeof settings.sourceText === 'string' && settings.sourceText === source);
    let html = md.renderer.render(tokens, md.options, env);
    if (/\\documentclass(?:\[|\{)|\\begin\{document\}/.test(source)) html = '<p class="renderer-note">此处支持 Markdown 内的数学公式与 AMS 环境；完整 LaTeX 文档的宏包和页面排版不在本阅读器范围内。未识别内容保留原文。</p>' + html;
    return html;
  }

  function validatedRange(item, quoteRanges) {
    if (!item || typeof item.id !== 'string' || typeof item.targetID !== 'string' || typeof item.quote !== 'string' || !item.quote || item.quote.length > 32_768) return null;
    const start = item.rangeLocation, length = item.rangeLength;
    if (Number.isSafeInteger(start) && Number.isSafeInteger(length) && start >= 0 && length > 0 && currentSource.slice(start, start + length) === item.quote) return [start, start + length];
    if (quoteRanges.has(item.quote)) return quoteRanges.get(item.quote);
    const found = currentSource.indexOf(item.quote);
    const result = found < 0 || currentSource.indexOf(item.quote, found + 1) >= 0 ? null : [found, found + item.quote.length];
    quoteRanges.set(item.quote, result);
    return result;
  }
  // Build once from the original trusted DOM. Marks inserted below do not add
  // source ranges. Preserve DOM order for literal hosts and shortest-block /
  // DOM-order ties for the honest paragraph fallback.
  function sourceIntervalIndex(nodes, startKey, endKey, shortest) {
    const entries = Array.from(nodes, (node, order) => ({ node, order, start: Number(node.dataset[startKey]), end: Number(node.dataset[endKey]) }))
      .filter(entry => Number.isFinite(entry.start) && Number.isFinite(entry.end))
      .sort((a, b) => a.start - b.start || a.order - b.order);
    const compare = shortest ? (a, b) => (a.end - a.start) - (b.end - b.start) || a.order - b.order : (a, b) => a.order - b.order;
    function build(first, last) {
      if (first >= last) return null;
      const middle = (first + last) >> 1, entry = entries[middle];
      const left = build(first, middle), right = build(middle + 1, last);
      let best = entry;
      if (left && compare(left.best, best) < 0) best = left.best;
      if (right && compare(right.best, best) < 0) best = right.best;
      return { entry, left, right, best, minStart: entries[first].start, maxEnd: Math.max(entry.end, left?.maxEnd ?? -Infinity, right?.maxEnd ?? -Infinity) };
    }
    const tree = build(0, entries.length);
    return (from, to) => {
      let best = null;
      function visit(branch) {
        if (!branch || branch.minStart > from || branch.maxEnd < to || (best && compare(branch.best, best) >= 0)) return;
        const entry = branch.entry;
        if (entry.start <= from && entry.end >= to && (!best || compare(entry, best) < 0)) best = entry;
        const a = branch.left, b = branch.right;
        if (a && b && compare(b.best, a.best) < 0) { visit(b); visit(a); }
        else { visit(a); visit(b); }
      }
      visit(tree);
      return best?.node ?? null;
    };
  }
  function addSourceDecorations(root, additions) {
    const incoming = additions || sourceDecorations;
    if (!incoming.length) return;
    const findHost = sourceIntervalIndex(root.querySelectorAll('[data-source-start]'), 'sourceStart', 'sourceEnd', false);
    const findBlock = sourceIntervalIndex(root.querySelectorAll('[data-source-block-start]'), 'sourceBlockStart', 'sourceBlockEnd', true);
    const quoteRanges = new Map();
    let approximateCount = 0;
    for (const item of incoming) {
      const range = validatedRange(item, quoteRanges);
      if (!range) continue;
      const host = findHost(range[0], range[1]);
      // One literal source span is sufficient. Never cross a math/link/code node.
      if (host) {
        const from = range[0] - Number(host.dataset.sourceStart), to = range[1] - Number(host.dataset.sourceStart);
        const walker = document.createTreeWalker(host, NodeFilter.SHOW_TEXT);
        let textNode, passed = 0, begin = null, finish = null;
        while ((textNode = walker.nextNode())) {
          const next = passed + textNode.length;
          if (!begin && from >= passed && from < next) begin = [textNode, from - passed];
          if (to > passed && to <= next) { finish = [textNode, to - passed]; break; }
          passed = next;
        }
        if (begin && finish) {
          const domRange = document.createRange(); domRange.setStart(...begin); domRange.setEnd(...finish);
          // Containment can be represented without changing source bytes or
          // cloning an existing mark: a sentence may contain clickable terms.
          // Crossing intervals have no honest nested DOM representation.
          const crosses = Array.from(host.querySelectorAll('.source-mention')).some(marker => {
            const start = Number(marker.dataset.decorationStart), end = Number(marker.dataset.decorationEnd);
            return (range[0] < start && start < range[1] && range[1] < end) ||
              (start < range[0] && range[0] < end && end < range[1]);
          });
          // If a new outer range ends at a nested mark's text boundary,
          // extractContents would otherwise clone that partly selected wrapper.
          // Promote exact boundaries to include the existing node itself.
          let startMark = begin[0].parentElement.closest('.source-mention');
          while (startMark && host.contains(startMark)) {
            if (Number(startMark.dataset.decorationStart) === range[0] && Number(startMark.dataset.decorationEnd) <= range[1]) domRange.setStartBefore(startMark);
            startMark = startMark.parentElement.closest('.source-mention');
          }
          let endMark = finish[0].parentElement.closest('.source-mention');
          while (endMark && host.contains(endMark)) {
            if (Number(endMark.dataset.decorationEnd) === range[1] && Number(endMark.dataset.decorationStart) >= range[0]) domRange.setEndAfter(endMark);
            endMark = endMark.parentElement.closest('.source-mention');
          }
          if (domRange.toString() === item.quote && !crosses) {
            const marker = document.createElement('span'); marker.className = 'source-mention';
            describeDecoration(marker, item, range);
            marker.tabIndex = 0; marker.setAttribute('role', 'button'); marker.setAttribute('aria-label', '查看“' + item.quote + '”的关联内容');
            marker.title = '查看关联内容';
            marker.appendChild(domRange.extractContents()); domRange.insertNode(marker); continue;
          }
        }
      }
      const block = findBlock(range[0], range[1]);
      if (block) {
        const marker = document.createElement('button'); marker.className = 'source-paragraph-link';
        describeDecoration(marker, item, range);
        marker.textContent = item.quote.length > 22 ? item.quote.slice(0, 22) + '…' : item.quote;
        marker.title = '定位到本段；此处的 Markdown 结构不支持可靠词位映射';
        marker.setAttribute('aria-label', marker.textContent + '，段落关联，非精确词位'); block.appendChild(marker); approximateCount++;
      }
    }
    if (approximateCount && !root.querySelector('.source-location-note')) {
      const note = document.createElement('p'); note.className = 'source-location-note';
      note.textContent = '部分关联显示在对应段落末尾；公式、链接或复杂排版保留原样，未推测词语位置。'; root.appendChild(note);
    }
  }
  function describeDecoration(marker, item, range) {
    marker.dataset.sourceDecoration = item.id; marker.dataset.sourceTarget = item.targetID;
    marker.dataset.sourceRole = item.interaction === 'term' ? 'term' : 'passage';
    marker.dataset.decorationStart = String(range[0]); marker.dataset.decorationEnd = String(range[1]);
  }
  function decorationIdentity(item) {
    return JSON.stringify([item.id, item.targetID, item.quote, item.rangeLocation, item.rangeLength, item.interaction === 'term' ? 'term' : 'passage']);
  }
  function applyDecorations() {
    const root = global.document?.getElementById('content');
    if (!root) return false;
    // Do not detach a reader's live text selection or an in-progress click.
    if (sourcePress || global.getSelection?.()?.isCollapsed === false) { decorationsDeferred = true; return false; }
    decorationsDeferred = false;
    const next = new Map(sourceDecorations.filter(item => item && typeof item.id === 'string').map(item => [item.id, decorationIdentity(item)]));
    const changedRanges = [];
    root.querySelectorAll('[data-source-decoration]').forEach(node => {
      const id = node.dataset.sourceDecoration;
      if (next.get(id) === appliedDecorations.get(id)) return;
      changedRanges.push([Number(node.dataset.decorationStart), Number(node.dataset.decorationEnd)]);
      if (node.classList.contains('source-mention')) node.replaceWith(...Array.from(node.childNodes));
      else node.remove();
    });
    const additions = sourceDecorations.filter(item => item && typeof item.id === 'string' && next.get(item.id) !== appliedDecorations.get(item.id));
    const quoteRanges = new Map();
    for (const item of additions) { const range = validatedRange(item, quoteRanges); if (range) changedRanges.push(range); }
    // A crossing neighbor may have forced an otherwise literal term into the
    // paragraph fallback. Retry only affected fallbacks after neighbors change.
    const retryIDs = new Set();
    root.querySelectorAll('.source-paragraph-link').forEach(node => {
      const from = Number(node.dataset.decorationStart), to = Number(node.dataset.decorationEnd);
      if (changedRanges.some(range => range[0] < to && from < range[1])) { retryIDs.add(node.dataset.sourceDecoration); node.remove(); }
    });
    for (const item of sourceDecorations) if (item && retryIDs.has(item.id) && !additions.some(value => value.id === item.id)) additions.push(item);
    addSourceDecorations(root, additions);
    appliedDecorations = next;
    if (!root.querySelector('.source-paragraph-link')) root.querySelectorAll('.source-location-note').forEach(node => node.remove());
    reportHeight();
    return true;
  }
  function updateDecorations(items, options) {
    if (Number(options?.revision) !== currentRevision) return false;
    sourceDecorations = Array.isArray(items) ? items.slice(0, 1_000) : [];
    return applyDecorations();
  }
  function updatePresentation(options) {
    if (Number(options?.revision) !== currentRevision) return false;
    selectionEnabled = !!options.selectionEnabled;
    document.documentElement.dataset.theme = options.theme === 'dark' ? 'dark' : 'light';
    document.documentElement.dataset.readingStyle = options.readingStyle === 'companion' ? 'companion' : 'body';
    const scale = Number.isFinite(Number(options.textScale)) ? Math.min(1.6, Math.max(0.8, Number(options.textScale))) : 1;
    document.documentElement.style.fontSize = ((options.readingStyle === 'companion' ? 18 : 16) * scale) + 'px';
    reportHeight();
    return true;
  }
  function focusDecoration(id) {
    const root = document.getElementById('content');
    root.querySelectorAll('.source-focused').forEach(node => node.classList.remove('source-focused'));
    const node = Array.from(root.querySelectorAll('[data-source-decoration]')).find(node => node.dataset.sourceDecoration === id);
    if (!node) return false;
    node.classList.add('source-focused');
    const revision = currentRevision;
    // First allow the fitted WebView to receive its new content height.
    global.requestAnimationFrame(() => global.requestAnimationFrame(() => {
      if (revision !== currentRevision || !node.isConnected) return;
      const rect = node.getBoundingClientRect(), parent = root.getBoundingClientRect();
      global.webkit?.messageHandlers?.readingbookSourceFocus?.postMessage({ y: Math.max(0, rect.top - parent.top - 12), height: rect.height + 24, revision });
    }));
    return true;
  }
  let heightScheduled = false;
  function reportHeight() {
    if (heightScheduled || !global.document) return;
    heightScheduled = true;
    global.requestAnimationFrame(() => {
      heightScheduled = false;
      const height = Math.ceil(document.getElementById('content').getBoundingClientRect().height + 2);
      global.webkit?.messageHandlers?.readingbookSize?.postMessage({ height, revision: currentRevision });
    });
  }
  function render(markdown, options) {
    const settings = options || {};
    currentRevision = Number(settings.revision) || 0;
    selectionEnabled = !!settings.selectionEnabled;
    currentSource = typeof settings.sourceText === 'string' ? settings.sourceText : String(markdown || '');
    sourceDecorations = Array.isArray(settings.sourceDecorations) ? settings.sourceDecorations.slice(0, 1_000) : [];
    global.getSelection?.()?.removeAllRanges();
    document.documentElement.dataset.theme = settings.theme === 'dark' ? 'dark' : 'light';
    document.documentElement.dataset.readingStyle = settings.readingStyle === 'companion' ? 'companion' : 'body';
    updatePresentation(settings);
    const root = document.getElementById('content');
    root.innerHTML = renderHTML(markdown, settings);
    appliedDecorations = new Map(); decorationsDeferred = false; sourcePress = null;
    addSourceDecorations(root);
    appliedDecorations = new Map(sourceDecorations.filter(item => item && typeof item.id === 'string').map(item => [item.id, decorationIdentity(item)]));
    root.querySelectorAll('img').forEach(image => {
      image.addEventListener('load', reportHeight, { once: true });
      image.addEventListener('error', () => {
        const placeholder = document.createElement('span');
        placeholder.className = 'image-placeholder'; placeholder.setAttribute('role', 'note');
        placeholder.textContent = '图片：' + image.alt + ' · 路径不在授权目录内、文件缺失或格式不受支持';
        image.replaceWith(placeholder); reportHeight();
      }, { once: true });
    });
    reportHeight();
    document.fonts?.ready.then(reportHeight);
  }
  global.ReadingBookMarkdown = Object.freeze({ render, renderHTML, focusDecoration, updateDecorations, updatePresentation });
  if (global.document) {
    let selectionTimer = null;
    let lastSelectionKey = '';
    function sourceMarker(target, interaction) {
      if (!target?.closest) return null;
      const nearest = target.closest('[data-source-decoration]');
      if (!nearest) return null;
      if (interaction === 'hover') {
        // Moving over a named term in a translated sentence keeps the sentence
        // translation steady; clicking the term opens its own entity card.
        return nearest.closest('.source-mention[data-source-role="passage"]') || nearest;
      }
      return nearest.closest('[data-source-role="term"]') || nearest;
    }
    function reportSourceHover(node, activated, event) {
      if (!node || (!activated && (sourcePress || global.getSelection()?.isCollapsed === false))) {
        global.webkit?.messageHandlers?.readingbookSourceHover?.postMessage({leaving:true,revision:currentRevision}); return;
      }
      const rectangles=Array.from(node.getClientRects());
      const rect=rectangles.find(rect=>event && event.clientX>=rect.left && event.clientX<=rect.right && event.clientY>=rect.top && event.clientY<=rect.bottom) || rectangles[0] || node.getBoundingClientRect();
      global.webkit?.messageHandlers?.readingbookSourceHover?.postMessage({id:node.dataset.sourceDecoration,rect:{x:rect.x,y:rect.y,width:rect.width,height:rect.height},activated:!!activated,revision:currentRevision});
    }
    document.addEventListener('mouseover', event => {
      const node=sourceMarker(event.target,'hover');
      if(node && node !== sourceMarker(event.relatedTarget,'hover')) reportSourceHover(node,false,event);
    });
    document.addEventListener('mouseout', event => {
      const node=sourceMarker(event.target,'hover');
      if(node && node !== sourceMarker(event.relatedTarget,'hover')) reportSourceHover(null,false);
    });
    function finishSourcePress() {
      const press = sourcePress;
      if (press?.node.isConnected) press.node.tabIndex = 0;
      sourcePress = null;
      if (decorationsDeferred) applyDecorations();
    }
    function reportSelection() {
      if (!selectionEnabled) return;
      const root = document.getElementById('content'), selection = global.getSelection();
      let text = '', containsMath = false, sourceLocation = null, sourceLength = null;
      if (root && selection && selection.rangeCount === 1 && !selection.isCollapsed &&
          root.contains(selection.anchorNode) && root.contains(selection.focusNode)) {
        const range = selection.getRangeAt(0);
        containsMath = Array.from(root.querySelectorAll('.math-inline, .math-display, .math-error')).some(node => range.intersectsNode(node));
        // KaTeX has an accessible MathML copy and a visual HTML copy. Preserve the
        // selected semantic text once; exact TeX belongs to the source selector.
        const fragment = range.cloneContents();
        fragment.querySelectorAll('.source-paragraph-link, .source-location-note').forEach(node => node.remove());
        fragment.querySelectorAll('.katex-mathml').forEach(node => node.remove());
        const container = document.createElement('div'); container.appendChild(fragment);
        container.querySelectorAll('br').forEach(node => node.replaceWith(document.createTextNode('\n')));
        container.querySelectorAll('p,li,pre,tr,h1,h2,h3,h4,h5,h6,blockquote,.math-display').forEach(node => node.appendChild(document.createTextNode('\n')));
        text = container.textContent || '';
        if (text.length > 32_768) text = ''; // Never silently truncate a saved excerpt.
        const sourcePoint = (node, offset) => {
          const parent = node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
          const host = parent?.closest?.('[data-source-start]');
          if (!host || !root.contains(host)) return null;
          const before = document.createRange(); before.selectNodeContents(host); before.setEnd(node, offset);
          return Number(host.dataset.sourceStart) + before.toString().length;
        };
        if (!containsMath) {
          const start = sourcePoint(range.startContainer, range.startOffset), end = sourcePoint(range.endContainer, range.endOffset);
          if (start !== null && end !== null && end > start && currentSource.slice(start, end) === text) {
            sourceLocation = start; sourceLength = end - start;
          }
        }
      }
      const key = currentRevision + ':' + containsMath + ':' + text;
      if (key === lastSelectionKey) return;
      lastSelectionKey = key;
      global.webkit?.messageHandlers?.readingbookSelection?.postMessage({ text, containsMath, sourceLocation, sourceLength, revision: currentRevision });
    }
    document.addEventListener('selectionchange', () => {
      clearTimeout(selectionTimer);
      selectionTimer = setTimeout(reportSelection, 80);
      if (decorationsDeferred && global.getSelection()?.isCollapsed !== false) applyDecorations();
    });
    new ResizeObserver(reportHeight).observe(document.getElementById('content'));
    global.addEventListener('resize', reportHeight);
    // Focusable inline spans can suppress native drag selection in Chromium /
    // WebKit. Keep keyboard focusability between gestures, while mouse selection
    // uses ordinary text behavior. No pointer capture or manual text offsets.
    document.addEventListener('mousedown', event => {
      finishSourcePress();
      reportSourceHover(null,false);
      const node = event.target.closest?.('.source-mention');
      if (!node || event.button !== 0) return;
      sourcePress = { node, x: event.clientX, y: event.clientY, dragged: false };
      if (document.activeElement === node) node.blur();
      node.removeAttribute('tabindex');
    }, true);
    document.addEventListener('mousemove', event => {
      if (sourcePress && Math.hypot(event.clientX - sourcePress.x, event.clientY - sourcePress.y) > 4) sourcePress.dragged = true;
    }, true);
    document.addEventListener('mouseup', () => {
      const press = sourcePress;
      setTimeout(() => { if (sourcePress === press) finishSourcePress(); }, 0);
    }, true);
    global.addEventListener('blur', finishSourcePress);
    document.addEventListener('click', event => {
      const marker = sourceMarker(event.target,'click');
      if (marker) {
        // A drag selection ending on a mention should remain a selection.
        if (event.detail !== 0 && (sourcePress?.dragged || global.getSelection()?.isCollapsed === false)) return;
        event.preventDefault();
        reportSourceHover(marker,true,event);
        global.webkit?.messageHandlers?.readingbookSourceTap?.postMessage({ id: marker.dataset.sourceDecoration, targetID: marker.dataset.sourceTarget, revision: currentRevision });
        return;
      }
      const link = event.target.closest?.('a');
      if (!link) return;
      event.preventDefault();
      if (link.dataset.unavailableLink) return;
      const href = link.getAttribute('href') || '';
      if (href.startsWith('#')) {
        try { document.getElementById(decodeURIComponent(href.slice(1)))?.scrollIntoView({ block: 'start' }); } catch (_) { }
      } else if (/^(readingbook:|https?:|mailto:)/i.test(href)) {
        global.webkit?.messageHandlers?.readingbookLink?.postMessage({ href, revision: currentRevision });
      }
    });
    document.addEventListener('keydown', event => {
      const marker = event.target.closest?.('[data-source-decoration]');
      if (marker && (event.key === 'Enter' || event.key === ' ')) {
        event.preventDefault(); marker.click();
      }
    });
  }
})(typeof window === 'undefined' ? globalThis : window);
