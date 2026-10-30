#!/usr/bin/env python3
"""Link completed testable product objects; optionally run owned WK correctness QA.

It never starts a product build. Default action links only; --run explicitly
launches the separate regression. Earlier baseline failures stay in evidence.
No provider settings, installed app, real library or general clipboard is used.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main(probe="bridge"):
    variants = {"bridge": ("NativeMarkdownBridgeProbe", "native-markdown-bridge-probe"),
                "input-identity": ("NativeMarkdownInputIdentityProbe", "native-markdown-input-probe"),
                "history-reference": ("NativeHistoryReferenceProbe", "native-history-reference-probe"),
                "bounded-idle": ("NativeMarkdownBoundedIdleProbe", "native-markdown-bounded-idle-probe")}
    if probe not in variants:
        raise ValueError("Unknown fixed native probe")
    probe_name, work_name = variants[probe]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--build-dir", type=Path, required=True,
                        help="Completed testable Debug bin dir; no build is initiated")
    parser.add_argument("--output-dir", type=Path, required=True,
                        help="Fresh directory to be created by probe if --run")
    parser.add_argument("--product-source-root", type=Path,
                        help="Required only for bounded-idle: exact source tree of the completed linked Debug objects")
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--show-window", action="store_true",
                        help="Only with --run in an allocated UI interval; activate owned regular app/key window for real RAF")
    args = parser.parse_args()
    root = args.workspace.resolve()

    def local(value):
        value = value if value.is_absolute() else root / value
        result = value.resolve()
        if not result.is_relative_to(root):
            raise ValueError("All source, inputs, build, cache and evidence must stay in workspace")
        return result

    location = local(Path(__file__).resolve().parent)
    source = local(location / (probe_name + ".swift"))
    observer = local(location / "dom-observations.js")
    build, output = local(args.build_dir), local(args.output_dir)
    idle_contract = None
    idle_source_inputs = {}
    idle_source_paths = []
    idle_product_source = None
    idle_contract_path = None
    if probe == "bounded-idle":
        if args.product_source_root is None:
            raise ValueError("bounded-idle requires the exact completed product --product-source-root")
        idle_product_source = local(args.product_source_root)
        idle_contract_path = local(location / "bounded-idle-check-contract.json")
        idle_contract = json.loads(idle_contract_path.read_text())
        names = idle_contract.get("checkNames", [])
        if (idle_contract.get("probe") != probe or idle_contract.get("sourceSHA256") != sha(source)
                or idle_contract.get("checkCount") != len(names) or not names or len(names) != len(set(names))):
            raise ValueError("Exact bounded-idle source/name contract missing or changed")
        idle_source_paths = [idle_product_source / "Sources/ReadingBook" / name for name in
                             ["MarkdownRenderer.swift", "ChatSaveViews.swift", "ReadingContinuationHistoryView.swift",
                              "ReadingViews.swift", "NoteMarkdownEditor.swift"]]
        if not all(path.is_file() for path in idle_source_paths):
            raise ValueError("Completed bounded-idle source tree is missing required scope files")
        idle_source_inputs = {str(path.relative_to(root)): sha(path) for path in idle_source_paths}
    elif args.product_source_root is not None:
        raise ValueError("--product-source-root applies only to bounded-idle")
    if args.show_window and not args.run:
        raise ValueError("--show-window requires --run")
    if probe in {"input-identity", "history-reference", "bounded-idle"} and args.run and not args.show_window:
        raise ValueError("This native regression requires an allocated foreground --show-window run")
    sidecars = {kind: output.with_name(output.name + suffix) for kind, suffix in
                [("identity", "-build.json"), ("compile", "-build.log"),
                 ("run", "-run.log"), ("source", "-source.swift"),
                 ("observer", "-observer.js")]}
    if output.exists() or any(path.exists() for path in sidecars.values()):
        raise FileExistsError("Fresh output name required; retain failures and never overwrite evidence")
    linkfile = build / "ReadingBook.product/Objects.LinkFileList"
    originals = [local(Path(path)) for path in linkfile.read_text().splitlines()]
    objects = [path for path in originals if path.name != "ReadingBookLauncher.swift.o"]
    if len(objects) != len(originals) - 1 or not all(path.is_file() for path in objects):
        raise ValueError("Expected exactly one launcher excluded and complete product objects")
    if not (build / "Modules/ReadingBook.swiftmodule").is_file():
        raise ValueError("Completed testable ReadingBook Debug module required")
    work = root / ".build" / work_name
    temporary = work / "tmp"
    fixed_home = work / "cf-home"
    cache, clang_cache = root / ".build/shared-module-cache/swift", root / ".build/shared-module-cache/clang"
    for directory in [work, temporary, fixed_home, cache, clang_cache, output.parent]:
        directory.mkdir(parents=True, exist_ok=True)
    binary = work / probe_name
    command = ["xcrun", "swiftc", "-parse-as-library", "-enable-testing", "-g", "-D", "DEBUG", "-swift-version", "5",
               "-I", str(build / "Modules"), "-module-cache-path", str(cache),
               "-module-name", probe_name, "-Xcc", f"-fmodules-cache-path={clang_cache}",
               str(source), *map(str, objects), "-o", str(binary)]
    environment = os.environ.copy()
    environment.update(TMPDIR=str(temporary), CFFIXED_USER_HOME=str(fixed_home), CLANG_MODULE_CACHE_PATH=str(clang_cache),
                       SWIFTPM_MODULECACHE_OVERRIDE=str(cache), SWIFT_MODULE_CACHE_PATH=str(cache),
                       MACOSX_DEPLOYMENT_TARGET="15.0")
    if idle_product_source is not None:
        environment["READINGBOOK_IDLE_SOURCE_ROOT"] = str(idle_product_source)
    sidecars["source"].write_bytes(source.read_bytes())
    sidecars["observer"].write_bytes(observer.read_bytes())
    before_objects = {str(path.relative_to(root)): sha(path) for path in objects}
    compiled = subprocess.run(command, cwd=root, env=environment, capture_output=True, text=True)
    sidecars["compile"].write_text(compiled.stdout + compiled.stderr)
    compiler_warnings = [line for line in compiled.stderr.splitlines() if "warning:" in line.casefold()]
    identity = {"command": command, "sourceSHA256": sha(source), "observerSHA256": sha(observer),
                "objects": before_objects, "compilerExitCode": compiled.returncode,
                "compilerWarnings": compiler_warnings,
                "sharedModuleCache": str(cache), "sharedClangModuleCache": str(clang_cache),
                "productBuildStarted": False, "runRequested": args.run,
                "ownedWindowRequested": args.show_window}
    if idle_contract is not None:
        identity.update(boundedIdleCheckContract=str(idle_contract_path), boundedIdleCheckContractSHA256=sha(idle_contract_path),
                        completedProductSourceRoot=str(idle_product_source), sourceInputs=idle_source_inputs)
    if compiled.returncode == 0:
        identity["binarySHA256"] = sha(binary)
    # Fail if a concurrent product build changed any linked input.
    identity["objectInputsStillFrozen"] = before_objects == {str(path.relative_to(root)): sha(path) for path in objects}
    identity["sourceInputsStillFrozen"] = idle_source_inputs == {str(path.relative_to(root)): sha(path) for path in idle_source_paths}
    sidecars["identity"].write_text(json.dumps(identity, indent=2) + "\n")
    if compiled.returncode or compiler_warnings or not identity["objectInputsStillFrozen"] or not identity["sourceInputsStillFrozen"]:
        print(compiled.stderr, file=sys.stderr)
        return compiled.returncode or 1
    if not args.run:
        print(json.dumps({"binary": str(binary), "builtOnly": True, "identity": str(sidecars["identity"])}))
        return 0
    run_command = [str(binary), str(root), str(output), str(observer)] + (["--show-window"] if args.show_window else [])
    try:
        run = subprocess.run(run_command, cwd=root, env=environment, capture_output=True, text=True, timeout=180)
        log = run.stdout + run.stderr
        code = run.returncode
    except subprocess.TimeoutExpired as error:
        log = (error.stdout or b"").decode(errors="replace") if isinstance(error.stdout, bytes) else error.stdout or ""
        log += (error.stderr or b"").decode(errors="replace") if isinstance(error.stderr, bytes) else error.stderr or ""
        log += "\nProbe timed out after 180 seconds. This run remains failed.\n"
        code = 124
    sidecars["run"].write_text(log)
    warnings = [pattern for pattern in ["300 iterations", "Publishing changes from within view updates", "AttributeGraph: cycle"] if pattern.casefold() in log.casefold()]
    result_path = output / "result.json"
    result = json.loads(result_path.read_text()) if result_path.exists() else {}
    checks = result.get("checks", {})
    passed = code == 0 and result.get("passed") is True and checks and all(value is True for value in checks.values()) and not warnings
    idle_actual = {}
    if idle_contract is not None:
        names = idle_contract["checkNames"]
        executed = result.get("executedCheckNames", [])
        source_frozen = idle_source_inputs == {str(path.relative_to(root)): sha(path) for path in idle_source_paths}
        exact_execution = (result.get("probe") == probe and result.get("checkCount") == len(checks) == len(names)
                           and set(checks) == set(names) and result.get("expectedCheckNames") == names
                           and result.get("expectedCheckCount") == len(names)
                           and len(executed) == len(set(executed)) == len(names) and set(executed) == set(names))
        passed = bool(passed and exact_execution and source_frozen)
        idle_actual = {"expectedCheckNames": names, "actualExecutedCheckNames": executed,
                       "exactNativeExecutionContractPassed": exact_execution,
                       "sourceInputsStillFrozenAfterRun": source_frozen}
    print(json.dumps({"probe": probe, "status": "passed" if passed else "failed", "output": str(output), "runtimeExitCode": code,
                      "passed": bool(passed), "checkCount": len(checks), "checks": checks, "runtimeWarnings": warnings,
                      "identity": str(sidecars["identity"]), "log": str(sidecars["run"]), **idle_actual}))
    return 0 if passed else code or 1


if __name__ == "__main__":
    sys.exit(main())
