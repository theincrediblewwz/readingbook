#!/usr/bin/env python3
"""Link the actual product objects into the isolated experience QA host."""
import argparse, hashlib, json, os, pathlib, plistlib, shutil, subprocess, sys
ROOT = pathlib.Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser()
p.add_argument('--bin-dir', type=pathlib.Path, required=True)
p.add_argument('--run-tag', default='native-ui')
a = p.parse_args()
assert a.run_tag.replace('-','').replace('_','').isalnum()
bindir = a.bin_dir.resolve()
assert bindir.is_relative_to(ROOT)
work = ROOT / '.build/experience-completion-host'
work.mkdir(parents=True, exist_ok=True)
source = pathlib.Path(__file__).with_name('ExperienceCompletionHost.swift')
objects = [x for x in (bindir/'ReadingBook.product/Objects.LinkFileList').read_text().splitlines() if not x.endswith('/ReadingBookLauncher.swift.o')]
assert objects
cache = ROOT/'.build/shared-module-cache/swift'
clang_cache = ROOT/'.build/shared-module-cache/clang'
cache.mkdir(parents=True, exist_ok=True); clang_cache.mkdir(parents=True, exist_ok=True)
(ROOT/'logs/ux-completion-20261031/tmp').mkdir(parents=True, exist_ok=True)
env = {**os.environ, 'CLANG_MODULE_CACHE_PATH':str(clang_cache), 'SWIFT_MODULECACHE_PATH':str(cache), 'TMPDIR':str(ROOT/'logs/ux-completion-20261031/tmp')}
binary = work/'ExperienceCompletionHost'
command = ['swiftc','-parse-as-library','-enable-testing','-g','-I',str(bindir/'Modules'),'-module-cache-path',str(cache),'-Xcc','-fmodules-cache-path='+str(clang_cache),'-module-name','ExperienceCompletionHost',str(source),*objects,'-o',str(binary)]
with (work/'compile.log').open('w') as log:
    result = subprocess.run(command,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT)
if result.returncode:
    print('Compilation failed; see .build/experience-completion-host/compile.log', file=sys.stderr); sys.exit(result.returncode)
app = work/'ReadingBook UX Test.app'
contents = app/'Contents'
(contents/'MacOS').mkdir(parents=True, exist_ok=True)
(contents/'Resources').mkdir(exist_ok=True)
shutil.copy2(binary, contents/'MacOS/ExperienceCompletionHost')
bundle = bindir/'ReadingBook_ReadingBook.bundle'
target = contents/'Resources'/bundle.name
if target.exists(): shutil.rmtree(target)
shutil.copytree(bundle, target)
run = ROOT/'logs/ux-completion-20261031'/a.run_tag
home = run/'home'; home.mkdir(parents=True, exist_ok=True)
(contents/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'org.readingbook.ux-completion-test','CFBundleExecutable':'ExperienceCompletionHost','CFBundleName':'ReadingBook UX Test','CFBundlePackageType':'APPL','NSHighResolutionCapable':True,'LSEnvironment':{'UX_COMPLETION_DIR':str(run),'UX_WORKSPACE_ROOT':str(ROOT),'CFFIXED_USER_HOME':str(home),'TMPDIR':str(ROOT/'logs/ux-completion-20261031/tmp')}}))
subprocess.run(['codesign','--force','--sign','-','--timestamp=none',str(app)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
(work/'manifest.json').write_text(json.dumps({'sourceSHA256':hashlib.sha256(source.read_bytes()).hexdigest(),'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),'binDir':str(bindir),'objects':[{'path':x,'sha256':hashlib.sha256(pathlib.Path(x).read_bytes()).hexdigest()} for x in objects]},indent=2))
print(app)
