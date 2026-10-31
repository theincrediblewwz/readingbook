/* Execute the shipped offline parser, without WebKit, a DOM, network or npm. */
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const resource = path.join(root, 'Sources/ReadingBook/Resources/Markdown');
const renderer = path.join(resource, 'renderer.js');
const vendor = path.join(resource, 'vendor/markdown-it/browser/markdown-it.umd.min.js');
const context = { markdownit: require(vendor) };
vm.runInNewContext(fs.readFileSync(renderer, 'utf8'), context, { filename: renderer, timeout: 3000 });
const render = context.ReadingBookMarkdown.renderHTML;
const marker = '<!-- conversation-message: 00000000-0000-4000-8000-000000000031 -->';
const results = [];
function check(name, source, options, verify) {
  const original = Buffer.from(source, 'utf8');
  let html;
  try {
    html = render(source, options || {});
    verify(html);
    assert.deepEqual(Buffer.from(source, 'utf8'), original);
    results.push({ name, passed: true, source, html });
  } catch (error) { results.push({ name, passed: false, source, html, error: String(error) }); }
}
check('standalone-host-marker-hidden-prose-retained', '前文。\n\n' + marker + '\n\n后文 e\u0301 👩🏽‍💻。', {}, html => {
  assert(!html.includes('conversation-message')); assert(html.includes('前文。')); assert(html.includes('后文 e\u0301 👩🏽‍💻。'));
});
check('adjacent-marker-interrupts-only-its-line', '前文。\n' + marker + '\n后文。', {}, html => {
  assert(!html.includes('conversation-message')); assert(html.includes('前文。')); assert(html.includes('后文。'));
});
check('fenced-code-marker-remains-visible', '```markdown\n' + marker + '\n```', {}, html => assert(html.includes('conversation-message') && html.includes('<code')));
check('inline-code-marker-remains-visible', '`' + marker + '`', {}, html => assert(html.includes('conversation-message') && html.includes('<code>')));
check('indented-code-marker-remains-visible', '    ' + marker, {}, html => assert(html.includes('conversation-message') && html.includes('<code>')));
check('blockquote-literal-marker-remains-visible', '> ' + marker, {}, html => assert(html.includes('conversation-message') && html.includes('<blockquote>')));
check('list-literal-marker-remains-visible', '- ' + marker, {}, html => assert(html.includes('conversation-message') && html.includes('<li>')));
check('ordinary-user-comment-remains-literal', '<!-- 自己的注释 -->', {}, html => assert(html.includes('自己的注释') && html.includes('&lt;!--')));
check('inline-marker-in-prose-remains-literal', '请看 ' + marker + ' 的格式', {}, html => assert(html.includes('conversation-message') && html.includes('的格式')));
check('invalid-marker-id-remains-visible', '<!-- conversation-message: <script> -->', {}, html => assert(html.includes('conversation-message') && !html.includes('<script>')));
check('oversize-marker-id-remains-visible', '<!-- conversation-message: ' + 'x'.repeat(129) + ' -->', {}, html => assert(html.includes('conversation-message')));
check('plain-source-reader-never-hides-host-shaped-text', marker, { plainText: true, sourceText: marker }, html => assert(html.includes('conversation-message') && html.includes('data-source-start="0"')));
const mapped = '前文。\n' + marker + '\n结尾 e\u0301 👩🏽‍💻。';
check('source-map-after-hidden-line-keeps-original-utf16-offset', mapped, { sourceText: mapped }, html => {
  assert(!html.includes('conversation-message')); assert(html.includes('data-source-start="' + mapped.indexOf('结尾') + '"'));
});
check('untrusted-html-stays-disabled', '<script>window.stolen=1</script>\n<img src="https://offline.invalid/x">', {}, html => {
  assert(!html.includes('<script>')); assert(!html.includes('<img ')); assert(html.includes('&lt;script&gt;'));
});
check('unrelated-link-label-and-url-stay-rendered', '[原文](readingbook://book/book-id/unit/u1)', {}, html => {
  assert(html.includes('readingbook://book/book-id/unit/u1')); assert(html.includes('原文'));
});
const output = path.resolve(root, process.argv[2] || 'logs/ci-markdown-bridge/provenance/result.json');
assert(output.startsWith(path.join(root, 'logs') + path.sep), 'Evidence must stay in workspace/logs');
assert(!fs.existsSync(output), 'Keep old results; choose a fresh output file');
fs.mkdirSync(path.dirname(output), { recursive: true });
const report = { status: results.every(x => x.passed) ? 'passed' : 'failed', checkCount: results.length, rendererSHA256: crypto.createHash('sha256').update(fs.readFileSync(renderer)).digest('hex'), vendorSHA256: crypto.createHash('sha256').update(fs.readFileSync(vendor)).digest('hex'), actualShippedRenderer: true, actualWebKit: false, checks: results };
fs.writeFileSync(output, JSON.stringify(report, null, 2) + '\n');
console.log('READINGBOOK_MARKDOWN_PROVENANCE ' + JSON.stringify({ ...report, checks: results.map(({name, passed}) => ({name, passed})) }));
if (report.status !== 'passed') process.exitCode = 1;
