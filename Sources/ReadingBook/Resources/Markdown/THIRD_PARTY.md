# Offline renderer resources

These files are bundled in the application. The renderer has no runtime CDN dependency.

- **markdown-it 15.0.2** — https://github.com/markdown-it/markdown-it — MIT.
  The unmodified npm browser UMD distribution is in `vendor/markdown-it/browser/`.
  Its full license is retained at `vendor/markdown-it/LICENSE`.
- **KaTeX 0.19.0** — https://github.com/KaTeX/KaTeX — MIT.
  Unmodified `katex.min.js`, `katex.min.css`, and all distribution WOFF2 fonts are
  in `vendor/katex/`. Its full license is retained at `vendor/katex/LICENSE`.

`vendor/versions.json` records the exact official npm registry URLs, archive
SHA-512 integrity values and SHA-256 hashes of every copied upstream file.
Archives were checked against the npm metadata before extracting selected files;
no package install scripts or third-party build tools were executed.

`renderer.js` supplies Markdown math rules before Markdown escaping, including
`$…$`, `$$…$$`, `\(…\)`, `\[…\]`, and supported bare AMS environments. Code is
excluded from math parsing. KaTeX uses untrusted mode with bounded expansion and
size; unsupported or unsafe formulas show their original source and an error.
This is not a full LaTeX document compiler or arbitrary LaTeX package runtime.

Security boundaries: Markdown raw HTML is disabled; code and error text are
escaped. CSP forbids remote requests, frames, objects, media, forms and inline
scripts. WebKit receives no `file://` read grant. Raster images require an explicit
`baseDirectory` grant and pass native containment, symlink, type, byte-size and
pixel-size checks. Image SVG is deliberately unsupported. Link navigation is
cancelled in WebKit and passed to SwiftUI's `openURL`; the app owns internal-link
handling and external-link policy.

Official references:

- https://markdown-it.github.io/markdown-it/interfaces/MarkdownIt.html
- https://katex.org/docs/options
- https://katex.org/docs/security
- https://katex.org/docs/autorender
- https://developer.apple.com/documentation/webkit/wkurlschemehandler
- https://developer.apple.com/documentation/webkit/wkwebview/loadfileurl(_:allowingreadaccessto:)
