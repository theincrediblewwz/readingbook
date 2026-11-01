#!/usr/bin/env python3
"""Run real PDFKit/Metal paper reading against the current linked product."""
import argparse, datetime, hashlib, json, os, pathlib, plistlib, shutil, subprocess, sys
ROOT = pathlib.Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser()
p.add_argument('--bin-dir', type=pathlib.Path, required=True)
p.add_argument('--tag', required=True)
a = p.parse_args()
assert a.tag.replace('-', '').isalnum()
bindir = a.bin_dir.resolve(); assert bindir.is_relative_to(ROOT)
output = ROOT/'logs/note-paper-20261101'/a.tag
assert not output.exists(), 'Use a fresh tag and preserve prior receipts'
output.mkdir(parents=True); (output/'home').mkdir(); (output/'tmp').mkdir()
work = ROOT/'.build/paper-reading-host'; work.mkdir(exist_ok=True)
source = pathlib.Path(__file__).with_name('PaperReadingHost.swift')
objects = [pathlib.Path(x) for x in (bindir/'ReadingBook.product/Objects.LinkFileList').read_text().splitlines() if not x.endswith('/ReadingBookLauncher.swift.o')]
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
swift_cache = ROOT/'.build/shared-module-cache/swift'; clang_cache = ROOT/'.build/shared-module-cache/clang'
environment = dict(os.environ, TMPDIR=str(output/'tmp'), CFFIXED_USER_HOME=str(output/'home'),
                   SWIFT_MODULECACHE_PATH=str(swift_cache), CLANG_MODULE_CACHE_PATH=str(clang_cache))
binary = work/'PaperReadingHost'
command = ['swiftc', '-parse-as-library', '-enable-testing', '-I', str(bindir/'Modules'), '-module-cache-path', str(swift_cache),
           '-Xcc', '-fmodules-cache-path='+str(clang_cache), str(source), *map(str, objects), '-o', str(binary)]
with (output/'compile.log').open('x') as log:
    built = subprocess.run(command, cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT)
assert built.returncode == 0, 'Paper-reading host compilation failed'
app = work/'ReadingBook Paper Regression.app'; contents = app/'Contents'
(contents/'MacOS').mkdir(parents=True, exist_ok=True); (contents/'Resources').mkdir(exist_ok=True)
shutil.copy2(binary, contents/'MacOS/PaperReadingHost')
bundle = contents/'Resources/ReadingBook_ReadingBook.bundle'
if bundle.exists(): shutil.rmtree(bundle)
shutil.copytree(bindir/'ReadingBook_ReadingBook.bundle', bundle)
(contents/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'org.readingbook.paper-regression', 'CFBundleExecutable': 'PaperReadingHost',
    'CFBundleName': 'ReadingBook Paper Regression', 'CFBundlePackageType': 'APPL', 'NSHighResolutionCapable': True}))
subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(app)], check=True, capture_output=True)
(output/'build-manifest.json').write_text(json.dumps({'sourceSHA256': sha(source), 'binarySHA256': sha(binary),
    'objects': {str(x.relative_to(ROOT)): sha(x) for x in objects}}, indent=2))
started = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
with (output/'runtime.log').open('x') as log:
    child = subprocess.Popen([str(contents/'MacOS/PaperReadingHost'), str(output)], cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT)
    try: status = child.wait(timeout=45)
    except subprocess.TimeoutExpired:
        subprocess.run(['sample', str(child.pid), '3', '-file', str(output/'timeout.sample.txt')], capture_output=True, timeout=10)
        child.kill(); status = child.wait()
logs = subprocess.run(['/usr/bin/log', 'show', '--style', 'compact', '--start', started, '--predicate', 'processIdentifier == '+str(child.pid)], capture_output=True, text=True, timeout=30)
runtime = logs.stdout + logs.stderr; (output/'unified.log').write_text(runtime)
warnings = {key: runtime.count(pattern) for key, pattern in [('layout300', '300 iterations'), ('publishingDuringViewUpdates', 'Publishing changes from within view updates'), ('attributeGraphCycles', 'AttributeGraph: cycle detected')]}
record = json.loads((output/'result.json').read_text()) if (output/'result.json').exists() else {}
passed = status == 0 and logs.returncode == 0 and not any(warnings.values()) and record.get('status') == 'passed'
report = {'probe': 'paper-reading', 'status': 'passed' if passed else 'failed', 'passed': passed, 'exitCode': status,
    'unifiedLogReturncode': logs.returncode, 'runtimeWarnings': warnings, 'hostSourceSHA256': sha(source), 'record': record, 'realNetworkRequests': 0}
(output/'report.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(report)); sys.exit(0 if passed else 1)
