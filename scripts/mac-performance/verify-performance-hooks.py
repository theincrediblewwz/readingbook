#!/usr/bin/env python3
"""Read-only replay of prepare.py literal hooks; no archive, build, app or GUI."""
import argparse
import ast
import difflib
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def inside(value):
    path = Path(value)
    path = (path if path.is_absolute() else ROOT / path).resolve()
    if path != ROOT and not path.is_relative_to(ROOT):
        raise ValueError("source/report paths must remain in this workspace")
    return path


def replay(source, prepare):
    if (source / "Sources/ReadingCore/PerfTrace.swift").exists() or "PerfProbe.bootstrap(" in (source / "Sources/ReadingBook/ReadingBookLauncher.swift").read_text():
        raise ValueError("hook verification expects raw product sources, not an already instrumented prepared tree")
    tree = ast.parse(prepare.read_text())
    originals, current, checks = {}, {}, []
    store = (source / "Sources/ReadingBook/AppStore.swift").read_text()

    def has_hooks(nodes):
        return any(isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == "patch"
                   for node in nodes for n in ast.walk(node))

    def visit(nodes):
        for node in nodes:
            if isinstance(node, ast.Expr) and isinstance(node.value, ast.Call) and isinstance(node.value.func, ast.Name) and node.value.func.id == "patch":
                rel, before, after = [ast.literal_eval(value) for value in node.value.args]
                if rel not in current:
                    originals[rel] = current[rel] = (source / rel).read_text()
                count = current[rel].count(before)
                checks.append(dict(path=rel, preimageCount=count, preimage=before))
                if count != 1:
                    raise ValueError(f"hook preimage must occur once: {rel}: found{count}: {before}")
                current[rel] = current[rel].replace(before, after, 1)
            elif isinstance(node, ast.If) and has_hooks(node.body + node.orelse):
                test = node.test
                if (isinstance(test, ast.Compare) and len(test.ops) == 1 and isinstance(test.ops[0], ast.In)
                        and isinstance(test.comparators[0], ast.Name) and test.comparators[0].id == "store_source"):
                    selected = ast.literal_eval(test.left) in store
                    visit(node.body if selected else node.orelse)
                else:
                    raise ValueError("unsupported conditional hook selector; review prepare.py: " + ast.dump(test))
            # Function definitions include patch's implementation, not invocations.
    visit(tree.body)
    for helper, target in [("PerfTrace.swift", "Sources/ReadingCore/PerfTrace.swift"), ("PerfProbe.swift", "Sources/ReadingBook/PerfProbe.swift")]:
        originals[target] = ""
        current[target] = (prepare.parent / helper).read_text()
    patch = "".join("".join(difflib.unified_diff(originals[path].splitlines(True), text.splitlines(True),
                                             fromfile="a/" + path, tofile="b/" + path))
                    for path, text in sorted(current.items()))
    report = {
        "status": "passed-read-only-hook-replay", "sourceRoot": str(source), "hookCount": len(checks), "checks": checks,
        "appStoreInitHook": "sharedAIRequests-injected-init" if "        self.sharedAIRequests = sharedAIRequests" in store else "legacy-empty-init",
        "freshProjectionHookPresent": 'PerfProbe.companionReady(page: store.selectedUnit?.page)' in current["Sources/ReadingBook/ReadingCompanionPanel.swift"],
        "cachedProjectionHookPresent": 'PerfProbe.companionReady(page: store.selectedUnit?.page, cached: true)' in current["Sources/ReadingBook/ReadingCompanionPanel.swift"],
        "productSourceWrites": False, "compiled": False, "executedApp": False,
        "prepareScriptSHA256": hashlib.sha256(prepare.read_bytes()).hexdigest(),
        "sourceInputSHA256": {path: hashlib.sha256(value.encode()).hexdigest() for path, value in originals.items() if value},
        "replayedDiffSHA256": hashlib.sha256(patch.encode()).hexdigest(),
    }
    return report, patch


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", default=str(ROOT))
    parser.add_argument("--output-prefix", required=True)
    args = parser.parse_args()
    source, output = inside(args.source_root), inside(args.output_prefix)
    if output.with_suffix(".json").exists() or output.with_suffix(".patch").exists():
        raise ValueError("outputs already exist; preserve earlier replay evidence")
    report, patch = replay(source, Path(__file__).with_name("prepare.py"))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.with_suffix(".json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    output.with_suffix(".patch").write_text(patch)
    print(json.dumps({k: report[k] for k in ["status", "hookCount", "appStoreInitHook", "freshProjectionHookPresent", "cachedProjectionHookPresent", "productSourceWrites", "compiled", "executedApp"]}))


if __name__ == "__main__":
    main()
