#!/usr/bin/env python3
"""Compile only: archived product Release with auditable diagnostic hooks."""
import argparse, datetime, difflib, hashlib, json, os, pathlib, plistlib, shutil, subprocess
TOOLS=pathlib.Path(__file__).resolve().parent
ROOT=pathlib.Path(subprocess.check_output(['git','-C',str(TOOLS),'rev-parse','--show-toplevel'],text=True).strip())
p=argparse.ArgumentParser();p.add_argument('--resume',action='store_true');p.add_argument('--ref',default='b164f6c');p.add_argument('--build-id',default='perf-harness-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'));a=p.parse_args()
assert a.build_id.replace('-','').replace('_','').isalnum()
base=ROOT/'.build'/a.build_id;base.mkdir(parents=True,exist_ok=a.resume)
source=base/'source';source.mkdir(exist_ok=a.resume);logs=ROOT/'logs'/a.build_id;logs.mkdir(parents=True,exist_ok=a.resume)
ref=subprocess.check_output(['git','rev-parse',a.ref+'^{commit}'],cwd=ROOT,text=True).strip()
archive=base/'tracked-source.tar'
if not a.resume:
 with archive.open('wb') as f:subprocess.run(['git','archive','--format=tar',ref],cwd=ROOT,stdout=f,check=True)
 subprocess.run(['tar','-xf',str(archive),'-C',str(source)],check=True)
changes=[]
def patch(rel,before,after):
 if a.resume:return
 target=source/rel;old=target.read_text();assert old.count(before)==1,(rel,'hook preimage must occur exactly once',old.count(before),before)
 new=old.replace(before,after,1);target.write_text(new)
 changes.extend(difflib.unified_diff(old.splitlines(True),new.splitlines(True),fromfile='a/'+rel,tofile='b/'+rel))
patch('Sources/ReadingBook/ReadingBookLauncher.swift','    @MainActor static func main() {','    @MainActor static func main() {\n        let perfMainEntry = PerfTrace.ticks()')
patch('Sources/ReadingBook/ReadingBookLauncher.swift','        ReadingBookApp.main()','        PerfProbe.bootstrap(mainEntry: perfMainEntry)\n        ReadingBookApp.main()')
patch('Sources/ReadingBook/ReadingBookApp.swift','import AppKit','import AppKit\nimport ReadingCore')
patch('Sources/ReadingBook/ReadingBookApp.swift','.background(FrostWindowAppearance())','.background(FrostWindowAppearance())\n                .background(PerfWindowProbe())')
patch('Sources/ReadingBook/ReadingBookApp.swift','.task { await store.load() }','.task {\n                    PerfTrace.event("store.load.request")\n                    await store.load()\n                    PerfTrace.event("store.load.completed")\n                    PerfProbe.storeLoaded(store)\n                }')
patch('Sources/ReadingBook/ReadingBookApp.swift','.defaultSize(width: 1480, height: 940)','.defaultSize(width: PerfProbe.config.width, height: PerfProbe.config.height)')
store_source = (source/'Sources/ReadingBook/AppStore.swift').read_text()
if '        self.sharedAIRequests = sharedAIRequests' in store_source:
    patch('Sources/ReadingBook/AppStore.swift','        self.sharedAIRequests = sharedAIRequests',
          '        PerfTrace.event("appstore.init.begin")\n        defer { PerfTrace.event("appstore.init.end") }\n        self.sharedAIRequests = sharedAIRequests')
else:
    patch('Sources/ReadingBook/AppStore.swift','    init() {','    init() {\n        PerfTrace.event("appstore.init.begin")\n        defer { PerfTrace.event("appstore.init.end") }')
patch('Sources/ReadingBook/AppStore.swift','            let report = try await repository.loadReport()','            PerfTrace.event("library.load-report.begin")\n            let report = try await repository.loadReport()\n            PerfTrace.event("library.load-report.end", ["bookCount": report.projects.count])')
patch('Sources/ReadingBook/AppStore.swift','    func selectBook(_ id: String, preferredRoute: String? = nil) async {','    func selectBook(_ id: String, preferredRoute: String? = nil) async {\n        PerfTrace.event("book.select.begin")\n        defer { PerfTrace.event("book.select.end") }')
patch('Sources/ReadingBook/WorkspaceMemory.swift','        UserDefaults.standard.set(book.id, forKey: "workspace-last-book-v1")','        PerfProbe.normalizeMemory(self)\n        UserDefaults.standard.set(book.id, forKey: "workspace-last-book-v1")')
patch('Sources/ReadingBook/PDFSessionAccess.swift','                var project = try await BookImporter.importFile(at: url, password: password)','                PerfTrace.event("import.parse.request")\n                var project = try await BookImporter.importFile(at: url, password: password)\n                PerfTrace.event("import.parse.completed", ["unitCount": project.units.count])')
patch('Sources/ReadingBook/PDFSessionAccess.swift','                project = try await repository.create(project, sourceURL: url)','                PerfTrace.event("import.repository-create.begin")\n                project = try await repository.create(project, sourceURL: url)\n                PerfTrace.event("import.repository-create.end")')
patch('Sources/ReadingCore/BookImporter.swift','        let hash = try sha256(data)','        let hash = try sha256(data)\n        PerfTrace.event("import.source-hash.ready", ["bytes": data.count])')
patch('Sources/ReadingCore/BookImporter.swift','        var units: [SourceUnit] = [], extractedBytes = 0','        PerfTrace.event("import.pdf-text.begin", ["pageCount": pdf.pageCount])\n        defer { PerfTrace.event("import.pdf-text.end") }\n        var units: [SourceUnit] = [], extractedBytes = 0')
patch('Sources/ReadingCore/LibraryRepository.swift','        try files.copyItem(at: source, to: destinationSource)','        PerfTrace.event("import.source-copy.begin")\n        try files.copyItem(at: source, to: destinationSource)\n        PerfTrace.event("import.source-copy.end")')
patch('Sources/ReadingBook/PDFReaderView.swift','        if pending.notifyParent { schedulePageCallback(pending.page) }','        PerfProbe.pdfReady(page: currentPageNumber ?? pending.page, token: lastParentNavigationToken ?? -1, zoom: Int((pdfView.scaleFactor * 100).rounded()), count: document?.pageCount ?? 0)\n        if pending.notifyParent { schedulePageCallback(pending.page) }')
patch('Sources/ReadingBook/PDFReaderView.swift','        guard let pdf = PDFDocument(url: url) else {','        PerfTrace.event("pdf.document-create.begin")\n        let perfDocument = PDFDocument(url: url)\n        PerfTrace.event("pdf.document-create.end")\n        guard let pdf = perfDocument else {')
patch('Sources/ReadingBook/PDFReaderView.swift','    private func position(at page: PDFPage, landing: PageLanding = .start) {','    private func position(at page: PDFPage, landing: PageLanding = .start) {\n        PerfTrace.event("pdf.position.begin")\n        defer { PerfTrace.event("pdf.position.end") }')
patch('Sources/ReadingBook/ReadingCompanionPanel.swift','            displayedScopeKey = expectedScope; displayedProjectionKey = expected; displayedPublicationStamp = book.publicationStamp','            displayedScopeKey = expectedScope; displayedProjectionKey = expected; displayedPublicationStamp = book.publicationStamp\n            PerfProbe.companionReady(page: store.selectedUnit?.page)')
patch('Sources/ReadingBook/ReadingCompanionPanel.swift','           displayedPublicationStamp == stamp { return }','           displayedPublicationStamp == stamp { PerfProbe.companionReady(page: store.selectedUnit?.page, cached: true); return }')
patch('Sources/ReadingBook/MarkdownRenderer.swift','        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {','        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {\n            PerfProbe.webViewReady(webView)')
for name,target in [('PerfTrace.swift','Sources/ReadingCore/PerfTrace.swift'),('PerfProbe.swift','Sources/ReadingBook/PerfProbe.swift')]:shutil.copy2(TOOLS/name,source/target)
changes=[]
for target in sorted((source/'Sources').rglob('*.swift')):
 rel=target.relative_to(source).as_posix()
 old=subprocess.run(['git','show',ref+':'+rel],cwd=ROOT,text=True,capture_output=True)
 original=old.stdout if old.returncode==0 else ''
 changes.extend(difflib.unified_diff(original.splitlines(True),target.read_text().splitlines(True),fromfile='a/'+rel,tofile='b/'+rel))
(logs/'instrumentation.patch').write_text(''.join(changes))
for name in ['tmp','swiftpm-cache']:(base/name).mkdir(exist_ok=a.resume)
shared=ROOT/'.build/shared-module-cache';swift_cache=shared/'swift';clang_cache=shared/'clang'
for cache in [swift_cache,clang_cache]:cache.mkdir(parents=True,exist_ok=True)
env=os.environ.copy();env.update(TMPDIR=str(base/'tmp'),CLANG_MODULE_CACHE_PATH=str(clang_cache),SWIFTPM_MODULECACHE_OVERRIDE=str(swift_cache),SWIFT_MODULE_CACHE_PATH=str(swift_cache))
args=['swift','build','--configuration','release','--product','ReadingBook','--scratch-path',str(base/'build'),'--cache-path',str(base/'swiftpm-cache'),'--disable-sandbox','-Xlinker','-lproc']
manifest={'sourceCommit':ref,'archiveSHA256':hashlib.sha256(archive.read_bytes()).hexdigest(),'buildRoot':str(base),'sourceRoot':str(source),'configuration':'release','enableTesting':False,'swiftBuildArguments':args,'instrumentationPatchSHA256':hashlib.sha256((logs/'instrumentation.patch').read_bytes()).hexdigest(),'probeSourcesSHA256':{x:hashlib.sha256((TOOLS/x).read_bytes()).hexdigest() for x in ['PerfTrace.swift','PerfProbe.swift']},'benchmarkExecuted':False}
(logs/'build-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
with (logs/'build.log').open('w') as log:subprocess.run(args,cwd=source,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
bindir=pathlib.Path(subprocess.check_output(args+['--show-bin-path'],cwd=source,env=env,text=True).strip())
app=base/'ReadingBook Performance Probe.app';contents=app/'Contents';(contents/'MacOS').mkdir(parents=True,exist_ok=True);(contents/'Resources').mkdir(exist_ok=True)
shutil.copy2(bindir/'ReadingBook',contents/'MacOS/ReadingBook');shutil.copytree(bindir/'ReadingBook_ReadingBook.bundle',contents/'Resources/ReadingBook_ReadingBook.bundle',dirs_exist_ok=True)
info=plistlib.loads((source/'packaging/Info.plist').read_bytes());info.update(CFBundleIdentifier='org.readingbook.perf-harness',CFBundleName='ReadingBook Performance Probe',CFBundleDisplayName='ReadingBook Performance Probe')
icon=pathlib.Path('/Applications/ReadingBook.app/Contents/Resources/AppIcon.icns')
if icon.exists():shutil.copy2(icon,contents/'Resources/AppIcon.icns')
(contents/'Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['codesign','--force','--sign','-','--timestamp=none',str(app)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True)
manifest.update(app=str(app),binarySHA256=hashlib.sha256((contents/'MacOS/ReadingBook').read_bytes()).hexdigest(),buildSucceeded=True)
for file in [logs/'build-manifest.json',base/'build-manifest.json']:file.write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps(manifest,indent=2))
