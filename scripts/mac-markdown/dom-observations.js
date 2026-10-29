/* Test-only observations for the actual bundled renderer in an owned WKWebView.
 * Inject once after loading the trusted document, outside every timed interval.
 * No renderer implementation is mirrored here. The host drives the actual native
 * update API and records its own selection/source/action callbacks.
 */
(() => {
  'use strict';
  if (window.ReadingBookBridgeObservations) throw new Error('Observer already installed');
  const captures = new Map();
  const root = () => {
    const value = document.getElementById('content');
    if (!value) throw new Error('Trusted renderer #content missing');
    return value;
  };
  const selection = () => {
    const value = window.getSelection();
    return value && {
      count: value.rangeCount, collapsed: value.isCollapsed,
      anchorNode: value.anchorNode, anchorOffset: value.anchorOffset,
      focusNode: value.focusNode, focusOffset: value.focusOffset,
      text: value.toString()
    };
  };
  const references = () => {
    const content = root();
    return {
      root: content,
      children: Array.from(content.childNodes),
      paragraphs: Array.from(content.querySelectorAll('p')),
      math: Array.from(content.querySelectorAll('.katex,.math-error')),
      marks: Array.from(content.querySelectorAll('[data-source-decoration]')),
      links: Array.from(content.querySelectorAll('a')),
      images: Array.from(content.querySelectorAll('img')),
      selected: selection()
    };
  };
  const sameNodes = (left, right) => left.length === right.length && left.every((node, index) => node === right[index] && node.isConnected);
  const selectionUnchanged = (left, right) => !!left && !!right &&
    left.count === right.count && left.collapsed === right.collapsed &&
    left.anchorNode === right.anchorNode && left.anchorOffset === right.anchorOffset &&
    left.focusNode === right.focusNode && left.focusOffset === right.focusOffset &&
    left.text === right.text;
  const describe = () => {
    const content = root(), current = selection(), style = getComputedStyle(document.documentElement);
    return {
      // Full values are for correctness only, never returned during timed calls.
      // Native host hashes the UTF-8 bytes; do not use Swift canonical equality.
      html: content.innerHTML, text: content.textContent,
      style: {theme: document.documentElement.dataset.theme,
        readingStyle: document.documentElement.dataset.readingStyle,
        readingContext: document.documentElement.dataset.readingContext,
        fontSize: style.fontSize, fontFamily: style.fontFamily},
      counts: {children: content.childNodes.length, paragraphs: content.querySelectorAll('p').length,
        math: content.querySelectorAll('.katex').length, mathErrors: content.querySelectorAll('.math-error').length,
        marks: content.querySelectorAll('[data-source-decoration]').length,
        tables: content.querySelectorAll('table').length, code: content.querySelectorAll('pre code').length},
      links: Array.from(content.querySelectorAll('a'), node => ({text: node.textContent,
        href: node.getAttribute('href'), unavailable: node.dataset.unavailableLink || null})),
      images: Array.from(content.querySelectorAll('img'), node => ({alt: node.alt,
        src: node.getAttribute('src'), complete: node.complete,
        naturalWidth: node.naturalWidth, naturalHeight: node.naturalHeight})),
      placeholders: Array.from(content.querySelectorAll('.image-placeholder'), node => node.textContent),
      marks: Array.from(content.querySelectorAll('[data-source-decoration]'), node => ({
        id: node.dataset.sourceDecoration, target: node.dataset.sourceTarget,
        role: node.dataset.sourceRole, text: node.textContent,
        start: node.dataset.decorationStart || null, end: node.dataset.decorationEnd || null})),
      selection: current && {count: current.count, collapsed: current.collapsed,
        anchorOffset: current.anchorOffset, focusOffset: current.focusOffset, text: current.text}
    };
  };
  window.ReadingBookBridgeObservations = Object.freeze({
    capture(name) {
      if (captures.has(name)) throw new Error('Capture name already used: ' + name);
      const value = references(); captures.set(name, value);
      return {captured: name, nonempty: value.children.length > 0,
        liveSelection: !!value.selected && value.selected.count === 1 && !value.selected.collapsed};
    },
    comparePresentation(name) {
      const before = captures.get(name);
      if (!before) throw new Error('No capture: ' + name);
      const after = references();
      return {rootIdentity: before.root === after.root,
        childrenIdentity: sameNodes(before.children, after.children),
        paragraphsIdentity: sameNodes(before.paragraphs, after.paragraphs),
        mathIdentity: sameNodes(before.math, after.math),
        marksIdentity: sameNodes(before.marks, after.marks),
        linksIdentity: sameNodes(before.links, after.links),
        imagesIdentity: sameNodes(before.images, after.images),
        selectionIdentityAndOffsets: selectionUnchanged(before.selected, after.selected)};
    },
    compareReplacement(name) {
      const before = captures.get(name);
      if (!before) throw new Error('No capture: ' + name);
      const after = references();
      return {sameRootExpected: before.root === after.root,
        oldChildrenDetached: before.children.every(node => !node.isConnected),
        newChildrenPresent: after.children.length > 0,
        selectionCleared: !after.selected || after.selected.collapsed || after.selected.count === 0};
    },
    selectUniqueText(text) {
      if (typeof text !== 'string' || !text) throw new Error('Nonempty fixture text required');
      const matches = [], walker = document.createTreeWalker(root(), NodeFilter.SHOW_TEXT);
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        let from = 0;
        for (let at = node.data.indexOf(text, from); at !== -1; at = node.data.indexOf(text, from)) {
          matches.push({node, at}); from = at + text.length;
        }
      }
      if (matches.length !== 1) throw new Error('Selection fixture must occur in one text node exactly once; got ' + matches.length);
      const {node, at} = matches[0], range = document.createRange(), current = window.getSelection();
      range.setStart(node, at); range.setEnd(node, at + text.length);
      current.removeAllRanges(); current.addRange(range);
      // Browser generates selectionchange; await the real renderer's 80 ms
      // debounce and native callback. This does not forge a bridge message.
      return {selected: current.toString(), start: at, length: text.length};
    },
    describe,
    release(name) { return captures.delete(name); }
  });
})();
