#!/usr/bin/env python3
"""Build a native fixture window against the actual product objects."""
from pathlib import Path
import argparse, hashlib, json, os, plistlib, shutil, subprocess
R = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser()
p.add_argument('--bin-dir', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--library-template', type=Path)
a = p.parse_args()
b, out = a.bin_dir.resolve(), a.output.resolve()
assert b.is_relative_to(R) and out.is_relative_to(R) and not out.exists()
out.mkdir(parents=True)
for name in ('home', 'tmp'): (out / name).mkdir()
if a.library_template:
    template = a.library_template.resolve()
    assert (template / 'books').is_dir()
    library = out / 'library'; library.mkdir()
    shutil.copytree(template / 'books', library / 'books')
    if (template / 'Workspace').is_dir(): shutil.copytree(template / 'Workspace', library / 'Workspace')
work = R / '.build/quiet-chrome-host'; work.mkdir(exist_ok=True)
source = Path(__file__).with_name('QuietChromeHost.swift')
objects = [x for x in (b / 'ReadingBook.product/Objects.LinkFileList').read_text().splitlines() if not x.endswith('/ReadingBookLauncher.swift.o')]
swift, clang = R / '.build/shared-module-cache/swift', R / '.build/shared-module-cache/clang'
env = dict(os.environ, TMPDIR=str(out / 'tmp'))
binary = work / 'QuietChromeHost'
if not (b / 'Modules/ReadingBook.swiftmodule').exists():
    # SwiftPM omits executable modules in some Release configurations. Emit
    # only its testable interface; reuse the already built product objects.
    sources = (b / 'ReadingBook.build/sources').read_text().splitlines()
    arch = b.parent.name.split('-apple-')[0]
    module = ['swiftc', '-O', '-swift-version', '5', '-target', arch + '-apple-macosx15.0', '-parse-as-library', '-enable-testing', '-emit-module', '-module-name', 'ReadingBook', '-emit-module-path', str(b / 'Modules/ReadingBook.swiftmodule'), '-I', str(b / 'Modules'), '-module-cache-path', str(swift), '-Xcc', '-fmodules-cache-path=' + str(clang), *sources]
    with (out / 'module.log').open('x') as log:
        result = subprocess.run(module, cwd=R, env=env, stdout=log, stderr=subprocess.STDOUT)
    assert result.returncode == 0, 'See ' + str(out / 'module.log')
cmd = ['swiftc', '-O', '-parse-as-library', '-enable-testing', '-I', str(b / 'Modules'), '-module-cache-path', str(swift), '-Xcc', '-fmodules-cache-path=' + str(clang), str(source), *objects, '-o', str(binary)]
with (out / 'compile.log').open('x') as log:
    result = subprocess.run(cmd, cwd=R, env=env, stdout=log, stderr=subprocess.STDOUT)
assert result.returncode == 0, 'See ' + str(out / 'compile.log')
app = work / 'ReadingBook Quiet Chrome Test.app'; c = app / 'Contents'
(c / 'MacOS').mkdir(parents=True, exist_ok=True); (c / 'Resources').mkdir(exist_ok=True)
shutil.copy2(binary, c / 'MacOS/QuietChromeHost')
resource = c / 'Resources/ReadingBook_ReadingBook.bundle'
if resource.exists(): shutil.rmtree(resource)
shutil.copytree(b / 'ReadingBook_ReadingBook.bundle', resource)
(c / 'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='org.readingbook.quiet-chrome-test', CFBundleExecutable='QuietChromeHost', CFBundleName='ReadingBook Quiet Chrome Test', CFBundlePackageType='APPL', NSHighResolutionCapable=True, LSEnvironment={'QUIET_CHROME_DIR': str(out), 'CFFIXED_USER_HOME': str(out / 'home'), 'TMPDIR': str(out / 'tmp'), 'QUIET_USE_LIBRARY': '1' if a.library_template else '0'})))
subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(app)], check=True, capture_output=True)
sha = lambda f: hashlib.sha256(Path(f).read_bytes()).hexdigest()
(out / 'build-manifest.json').write_text(json.dumps(dict(hostSourceSHA256=sha(source), binarySHA256=sha(binary), binDir=str(b), objects=[dict(path=x, sha256=sha(x)) for x in objects]), indent=2) + '\n')
print(app)
