#!/usr/bin/env python3
"""Link completed Debug product objects into the offline AppStore continuation probe."""
import argparse
import hashlib
import json
import os
import pathlib
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--bin-dir', type=pathlib.Path, required=True,
                    help='An already completed ReadingBook Debug object directory; never builds the product')
parser.add_argument('--output', type=pathlib.Path, default=pathlib.Path('.build/reading-continuation-probe'))
args = parser.parse_args()
bindir = (ROOT / args.bin_dir).resolve()
work = (ROOT / args.output).resolve()
if not bindir.is_relative_to(ROOT) or not work.is_relative_to(ROOT / '.build') or work == ROOT / '.build':
    raise ValueError('Completed objects and helper output must remain in this workspace')
source = ROOT / 'scripts/native-ui-regression/ReadingContinuationProbe.swift'
objects = (bindir / 'ReadingBook.product/Objects.LinkFileList').read_text().splitlines()
linked = [item for item in objects if not item.endswith('/ReadingBookLauncher.swift.o')]
if len(linked) != len(objects) - 1 or not linked:
    raise ValueError('Exactly one product launcher must be excluded')
if not all(pathlib.Path(item).is_file() and pathlib.Path(item).resolve().is_relative_to(ROOT) for item in linked):
    raise ValueError('Only completed workspace-local object files may be linked')
for directory in [work / 'tmp', ROOT / '.build/shared-module-cache/swift', ROOT / '.build/shared-module-cache/clang']:
    directory.mkdir(parents=True, exist_ok=True)
swift_cache = ROOT / '.build/shared-module-cache/swift'
clang_cache = ROOT / '.build/shared-module-cache/clang'
env = os.environ.copy()
env.update(TMPDIR=str(work / 'tmp'), CLANG_MODULE_CACHE_PATH=str(clang_cache),
           SWIFTPM_MODULECACHE_OVERRIDE=str(swift_cache), SWIFT_MODULE_CACHE_PATH=str(swift_cache))
binary = work / 'reading-continuation-probe'
command = ['swiftc', '-parse-as-library', '-enable-testing', '-g', '-I', str(bindir / 'Modules'),
           '-module-cache-path', str(swift_cache), '-Xcc', '-fmodules-cache-path=' + str(clang_cache),
           '-module-name', 'ReadingContinuationProbe', str(source), *linked, '-o', str(binary)]
with (work / 'compile.log').open('w') as log:
    subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
manifest = {'sourceSHA256': hashlib.sha256(source.read_bytes()).hexdigest(),
            'builderSHA256': hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),
            'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'productBinDir': str(bindir),
            'productObjects': [{'file': str(pathlib.Path(item).relative_to(ROOT)),
                                'sha256': hashlib.sha256(pathlib.Path(item).read_bytes()).hexdigest()} for item in linked],
            'sharedSwiftModuleCache': str(swift_cache), 'sharedClangModuleCache': str(clang_cache),
            'realNetworkRequests': 0, 'runtimeTested': False, 'guiLaunched': False,
            'launchArguments': [str(binary), '--workspace', str(ROOT), '--output',
                                str(ROOT / 'logs/reading-continuation-probe-NEW-RUN')]}
(work / 'build-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
shutil.copy2(source, work / 'compiled-probe-source.swift')
print(json.dumps({'binary': str(binary), 'objectCount': len(linked), 'manifest': str(work / 'build-manifest.json')}, indent=2))
