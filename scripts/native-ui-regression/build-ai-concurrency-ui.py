#!/usr/bin/env python3
"""Link/package an offline native workspace using completed Debug objects; never launch it."""
import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--workspace', type=pathlib.Path, default=ROOT)
parser.add_argument('--bin-dir', type=pathlib.Path, required=True,
                    help='Already completed testable Debug product; no product build is started')
parser.add_argument('--output', type=pathlib.Path, default=ROOT / '.build/ai-concurrency-ui',
                    help='Package/build directory, strictly inside this workspace .build')
args = parser.parse_args()
workspace = args.workspace.resolve()
if workspace != ROOT:
    raise ValueError('Workspace must be the repository containing this builder')
bindir = (workspace / args.bin_dir).resolve()
work = (workspace / args.output).resolve()
if not bindir.is_relative_to(workspace) or not work.is_relative_to(workspace / '.build') or work == workspace / '.build':
    raise ValueError('Completed objects and package output must remain inside this workspace')
objects = (bindir / 'ReadingBook.product/Objects.LinkFileList').read_text().splitlines()
linked = [item for item in objects if not item.endswith('/ReadingBookLauncher.swift.o')]
if len(linked) != len(objects) - 1 or not all(pathlib.Path(item).resolve().is_relative_to(workspace) for item in linked):
    raise ValueError('Expected exactly one excluded launcher and workspace-local objects')
for name in ['tmp']:
    (work / name).mkdir(parents=True, exist_ok=True)
source = workspace / 'scripts/native-ui-regression/AIConcurrencyUIHost.swift'
binary = work / 'ai-concurrency-ui-host'
shared = ROOT / '.build/shared-module-cache'
swift_cache, clang_cache = shared / 'swift', shared / 'clang'
for cache in [swift_cache, clang_cache]:
    cache.mkdir(parents=True, exist_ok=True)
env = os.environ.copy()
env.update(TMPDIR=str(work / 'tmp'), CLANG_MODULE_CACHE_PATH=str(clang_cache),
           SWIFTPM_MODULECACHE_OVERRIDE=str(swift_cache), SWIFT_MODULE_CACHE_PATH=str(swift_cache))
command = ['swiftc', '-parse-as-library', '-enable-testing', '-g', '-I', str(bindir / 'Modules'),
           '-module-cache-path', str(swift_cache), '-Xcc', '-fmodules-cache-path=' + str(clang_cache), '-module-name', 'AIConcurrencyUIHost',
           str(source), *linked, '-o', str(binary)]
with (work / 'compile.log').open('w') as log:
    subprocess.run(command, cwd=workspace, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
app = work / 'ReadingBook Offline Concurrency.app'
domain = 'org.readingbook.ui-concurrency-test'
if app.exists():
    metadata = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if metadata.get('CFBundleIdentifier') != domain:
        raise ValueError('Refusing to replace a bundle that is not this throwaway UI host')
    shutil.rmtree(app)
contents = app / 'Contents'
(contents / 'MacOS').mkdir(parents=True)
(contents / 'Resources').mkdir()
executable = contents / 'MacOS/ReadingBookOfflineConcurrency'
shutil.copy2(binary, executable)
shutil.copytree(bindir / 'ReadingBook_ReadingBook.bundle', contents / 'Resources/ReadingBook_ReadingBook.bundle')
(contents / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': domain, 'CFBundleExecutable': executable.name, 'CFBundleName': 'ReadingBook 离线测试',
    'CFBundleDisplayName': 'ReadingBook 离线测试', 'CFBundlePackageType': 'APPL',
    'CFBundleVersion': '1', 'NSHighResolutionCapable': True, 'LSUIElement': False,
    'NSHumanReadableCopyright': 'Offline fixture. No installed library or provider credentials.'}))
subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(app)],
               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
manifest = {'sourceSHA256': hashlib.sha256(source.read_bytes()).hexdigest(),
            'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest(),
            'productBinDir': str(bindir), 'app': str(app), 'bundleIdentifier': domain,
            'productObjects': [{'file': str(pathlib.Path(item).relative_to(workspace)),
                                'sha256': hashlib.sha256(pathlib.Path(item).read_bytes()).hexdigest()}
                               for item in linked], 'realNetworkRequests': 0,
            'launchArguments': [str(executable), '--workspace', str(workspace), '--output',
                                str(workspace / 'logs/ai-concurrency-ui-NEW-RUN')]}
(work / 'build-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
shutil.copy2(source, work / 'compiled-ui-host-source.swift')
print(json.dumps({'app': str(app), 'binary': str(executable), 'objectCount': len(linked),
                  'note': 'Not launched. Supply a new workspace-local --output directory.'}, indent=2))
