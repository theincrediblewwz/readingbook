/* ReadingBook's trusted offline renderer. Input is Markdown data, never executable HTML. */
(function (global) {
  'use strict';
  const md = global.markdownit({ html: false, linkify: true, typographer: false, breaks: false });
  const escape = md.utils.escapeHtml;
  const environments = '(?:equation|align|alignat|gather|multline|aligned|alignedat|gathered|split|cases|matrix|pmatrix|bmatrix|Bmatrix|vmatrix|Vmatrix|smallmatrix|CD)\\*?';
  const beginEnvironment = new RegExp('^\\\\begin\\{(' + environments + ')\\}');
  let currentRevision = 0;

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
  md.renderer.rules.readingbook_math = (tokens, index) => mathHTML(tokens[index].content, tokens[index].meta.display, tokens[index].meta.original);
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
  md.renderer.rules.table_open = () => '<div class="table-scroll" tabindex="0" role="region" aria-label="表格，可横向滚动"><table>\n';
  md.renderer.rules.table_close = () => '</table></div>\n';
  const defaultHeading = md.renderer.rules.heading_open || ((tokens, index, options, env, renderer) => renderer.renderToken(tokens, index, options));
  md.renderer.rules.heading_open = function (tokens, index, options, env, renderer) {
    const title = tokens[index + 1]?.content || 'heading';
    const stem = title.toLowerCase().replace(/[^\p{L}\p{N} _-]/gu, '').trim().replace(/\s+/g, '-') || 'heading';
    const count = env.headings[stem] || 0; env.headings[stem] = count + 1;
    tokens[index].attrSet('id', stem + (count ? '-' + count : ''));
    return defaultHeading(tokens, index, options, env, renderer);
  };

  function renderHTML(markdown, options) {
    const settings = options || {};
    const source = String(markdown || '');
    if (source.length > 2_000_000) return '<p class="renderer-note">此段内容过长，请按章节查看；原文未被截断保存。</p>';
    let html = md.render(source, { allowImages: !!settings.allowImages, revision: Number(settings.revision) || 0, headings: Object.create(null) });
    if (/\\documentclass(?:\[|\{)|\\begin\{document\}/.test(source)) html = '<p class="renderer-note">此处支持 Markdown 内的数学公式与 AMS 环境；完整 LaTeX 文档的宏包和页面排版不在本阅读器范围内。未识别内容保留原文。</p>' + html;
    return html;
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
    document.documentElement.dataset.theme = settings.theme === 'dark' ? 'dark' : 'light';
    const root = document.getElementById('content');
    root.innerHTML = renderHTML(markdown, settings);
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
  global.ReadingBookMarkdown = Object.freeze({ render, renderHTML });
  if (global.document) {
    new ResizeObserver(reportHeight).observe(document.getElementById('content'));
    global.addEventListener('resize', reportHeight);
    document.addEventListener('click', event => {
      const link = event.target.closest?.('a');
      if (!link) return;
      event.preventDefault();
      if (link.dataset.unavailableLink) return;
      const href = link.getAttribute('href') || '';
      if (href.startsWith('#')) {
        try { document.getElementById(decodeURIComponent(href.slice(1)))?.scrollIntoView({ block: 'start' }); } catch (_) { }
      } else if (/^(readingbook:|https?:|mailto:)/i.test(href)) {
        global.webkit?.messageHandlers?.readingbookLink?.postMessage({ href });
      }
    });
  }
})(typeof window === 'undefined' ? globalThis : window);
