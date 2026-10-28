#!/usr/bin/env python3
"""Build/run only the isolated note editor after the coordinated Debug build.

All compiler output, module caches, temporary files and evidence stay in this
workspace. No app window, real library or general clipboard is used.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def local(path):
    result = Path(path).resolve()
    if not result.is_relative_to(ROOT):
        raise ValueError(f"Path must stay inside the workspace: {result}")
    return result


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", required=True, help="Completed Debug directory containing Modules/ and ReadingCore.build/")
    parser.add_argument("--output", required=True, help="Workspace-local result JSON path")
    args = parser.parse_args()
    build = local(args.build_dir)
    output = local(args.output)
    build_log = output.with_name(output.stem + "-build.log")
    build_identity = output.with_name(output.stem + "-build.json")
    run_log = output.with_name(output.stem + "-run.log")
    if any(path.exists() for path in [output, build_log, build_identity, run_log]):
        raise FileExistsError("Use a fresh output stem; previous probe evidence is never overwritten.")
    module = build / "Modules" / "ReadingCore.swiftmodule"
    objects = sorted((build / "ReadingCore.build").glob("*.o"))
    if not module.is_file() or not objects or not any("ReadingNoteLinkFolds" in path.name for path in objects):
        raise RuntimeError("First finish the coordinated Debug build including ReadingNoteLinkFolds.swift; no product build is started here.")
    output.parent.mkdir(parents=True, exist_ok=True)
    work = ROOT / ".build/native-note-probe"
    for name in ["tmp"]:
        (work / name).mkdir(parents=True, exist_ok=True)
    shared = ROOT / ".build/shared-module-cache"
    swift_cache, clang_cache = shared / "swift", shared / "clang"
    for cache in [swift_cache, clang_cache]:
        cache.mkdir(parents=True, exist_ok=True)
    binary = work / "NativeNoteEditorProbe"
    editor = ROOT / "Sources/ReadingBook/NoteMarkdownEditor.swift"
    core = ROOT / "Sources/ReadingCore/ReadingNoteLinkFolds.swift"
    probe = ROOT / "scripts/mac-note-editor/NativeNoteEditorProbe.swift"
    command = ["xcrun", "swiftc", "-parse-as-library", "-D", "DEBUG", "-swift-version", "5",
        "-module-cache-path", str(swift_cache), "-Xcc", f"-fmodules-cache-path={clang_cache}",
        "-I", str(build / "Modules"), str(editor), str(probe), *map(str, objects), "-o", str(binary)]
    environment = os.environ.copy()
    environment.update(TMPDIR=str(work / "tmp"), CLANG_MODULE_CACHE_PATH=str(clang_cache),
        SWIFT_MODULE_CACHE_PATH=str(swift_cache), MACOSX_DEPLOYMENT_TARGET="15.0")
    compiled = subprocess.run(command, cwd=ROOT, env=environment, capture_output=True, text=True)
    build_log.write_text(compiled.stdout + compiled.stderr)
    identity = {"command": command, "sources": {str(path.relative_to(ROOT)): sha(path) for path in [editor, core, probe]},
        "coreObjects": {str(path.relative_to(ROOT)): sha(path) for path in objects}, "exitCode": compiled.returncode}
    if compiled.returncode == 0:
        identity["probeBinarySHA256"] = sha(binary)
    build_identity.write_text(json.dumps(identity, indent=2) + "\n")
    if compiled.returncode:
        print(compiled.stderr, file=sys.stderr)
        return compiled.returncode
    result = subprocess.run([str(binary), str(output)], cwd=ROOT, env=environment, capture_output=True, text=True)
    run_log.write_text(result.stdout + result.stderr)
    print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
