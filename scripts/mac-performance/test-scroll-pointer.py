#!/usr/bin/env python3
"""Compile and run current ScrollDrive pointer correctness with hidden native windows.

No product build, archived driver, OS input, pointer movement or performance test.
Every invocation retains a fresh workspace-local evidence directory, including failures.
"""
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parents[1]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    with path.open("x") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write("\n")


def validate(value):
    require(value.get("passed") is True and value.get("mode") == "current-driver-with-formula-mutant", "Current actual driver did not pass")
    require(value.get("caseCount") == 10 and value.get("actualFailures") == 0, "Expected exactly ten successful coordinate cases")
    require(value.get("oldBugReproduced") is True and value.get("oldCoordinateDisagreements") == 2
            and value.get("nonFlippedOldDisagreements") == 0 and value.get("flippedOldDisagreements") == 2,
            "The old formula mutant must reproduce exactly two flipped-root errors")
    require(value.get("activationPolicyProhibited") is True and value.get("allWindowsRemainedHidden") is True
            and value.get("appWasNeverActive") is True and value.get("systemPointerMovedByTest") is False,
            "Native test must remain hidden and prohibited from activation or pointer injection")
    names = {"pdf-center": True, "pdf-visual-bottom": True, "toolbar-center": False,
             "above-content": False, "left-of-window": False}
    rows = value.get("rows", [])
    require(len(rows) == 10 and {(row.get("rootFlipped"), row.get("case")) for row in rows}
            == {(flipped, name) for flipped in (False, True) for name in names}, "Missing/duplicate positive or negative coordinate case")
    disagreements = {False: 0, True: 0}
    for row in rows:
        expected = names[row["case"]]
        require(isinstance(row.get("rootFlipped"), bool) and row.get("expectedPDF") is expected
                and row.get("actualDriverHitsPDF") is expected and row.get("superviewHitsPDF") is expected
                and row.get("passed") is True and row.get("windowWasNeverOrderedFront") is True
                and row.get("nativePDFPages") == 1, "Native actual/oracle/hidden case failed: " + row["case"])
        geometry = row.get("actualDriverGeometry", {})
        require(geometry.get("available") is True and geometry.get("hitTestCoordinateSpace") == "content-superview"
                and geometry.get("hitsPDF") is expected, "Current actual geometry method was not observed")
        if row.get("oldHitsPDF") is not expected:
            disagreements[row["rootFlipped"]] += 1
    require(disagreements == {False: 0, True: 2}, "Mutant errors do not match the raw cases")


def main():
    require(len(sys.argv) == 1, "This test takes no arguments or legacy driver variants")
    require(platform.system() == "Darwin", "Native pointer correctness requires macOS; never silently skip")
    require((ROOT / "Package.swift").is_file(), "Cannot locate the ReadingBook repository from this tool")
    source = TOOLS / "ScrollDrive.m"
    native = TOOLS / "ScrollPointerCoordinates.m"
    inputs = {"driverSource": source, "nativeTestSource": native, "runnerTool": Path(__file__).resolve()}
    require(all(path.is_file() and path.resolve().is_relative_to(ROOT) for path in inputs.values()), "All source/tool inputs must be inside this repository")
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    output = ROOT / ".build/scroll-pointer-tests" / (stamp + "-" + str(os.getpid()))
    output.mkdir(parents=True, mode=0o700)
    cache = ROOT / ".build/shared-module-cache/clang"
    cache.mkdir(parents=True, exist_ok=True)
    for name in ("tmp", "cf-home", "sources"):
        (output / name).mkdir()
    before = {name: sha(path) for name, path in inputs.items()}
    for name, path in inputs.items():
        (output / "sources" / path.name).write_bytes(path.read_bytes())
    binary, native_result = output / "ScrollPointerCoordinates", output / "native-result.json"
    compile_log, run_log = output / "compile.log", output / "run.log"
    command = ["xcrun", "clang", "-fobjc-arc", "-O0", "-mmacosx-version-min=15.0", "-fmodules",
               "-fmodules-cache-path=" + str(cache), "-Wall", "-Wextra", "-Werror", str(native),
               "-framework", "Foundation", "-framework", "AppKit", "-framework", "PDFKit", "-framework", "CoreGraphics",
               "-lproc", "-o", str(binary)]
    run_command = [str(binary), str(native_result)]
    environment = os.environ.copy()
    removed = sorted(key for key in environment if key.startswith("READINGBOOK_SCROLL_") or key == "DYLD_INSERT_LIBRARIES")
    for key in removed:
        environment.pop(key)
    fixed_environment = {"TMPDIR": str(output / "tmp"), "CFFIXED_USER_HOME": str(output / "cf-home"),
                         "CLANG_MODULE_CACHE_PATH": str(cache)}
    environment.update(fixed_environment)
    commands_path = output / "commands.json"
    write_json(commands_path, {"compile": command, "run": run_command, "workingDirectory": str(ROOT),
                               "fixedEnvironment": fixed_environment, "removedEnvironmentKeyNames": removed})
    record = {"status": "failed", "mode": "native-pointer-coordinate-correctness", "evidenceDirectory": str(output),
              "sourcePaths": {name: str(path.relative_to(ROOT)) for name, path in inputs.items()},
              "inputSHA256Before": before, "commandsSHA256": sha(commands_path), "sharedModuleCache": str(cache),
              "productBuildStarted": False, "archivedDriverExecuted": False, "performanceMeasurement": False}
    try:
        with compile_log.open("x") as log:
            compiled = subprocess.run(command, cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT, timeout=90)
        record["compileExitCode"] = compiled.returncode
        record["compilerWarnings"] = [line for line in compile_log.read_text().splitlines() if re.search(r"\bwarning:", line, re.IGNORECASE)]
        require(compiled.returncode == 0 and not record["compilerWarnings"], "Native correctness compilation failed or warned; no retry")
        record["binarySHA256"] = sha(binary)
        with run_log.open("x") as log:
            ran = subprocess.run(run_command, cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT, timeout=30)
        record["runExitCode"] = ran.returncode
        require(ran.returncode == 0 and native_result.is_file(), "Native coordinate run failed; original attempt retained")
        value = json.loads(native_result.read_text())
        validate(value)
        record.update(checkCount=value["caseCount"], oldBugErrorsReproduced=value["oldCoordinateDisagreements"],
                      allNativeWindowsHidden=value["allWindowsRemainedHidden"], activationPolicyProhibited=value["activationPolicyProhibited"],
                      systemPointerMovedByTest=value["systemPointerMovedByTest"], nativeResultPath=str(native_result))
        record["inputSHA256After"] = {name: sha(path) for name, path in inputs.items()}
        require(record["inputSHA256After"] == before, "Actual source/tool changed during this test")
        record["status"] = "passed"
    except Exception as error:
        record["error"] = str(error)
    finally:
        record["evidenceSHA256"] = {path.name: sha(path) for path in (commands_path, compile_log, run_log, native_result) if path.is_file()}
        write_json(output / "invocation.json", record)
    print(json.dumps(record, ensure_ascii=False, indent=2))
    return 0 if record["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
