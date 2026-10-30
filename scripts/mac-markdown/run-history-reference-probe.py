#!/usr/bin/env python3
"""Run real saved-history reference, reflow and native scroll correctness guards."""
from pathlib import Path
from runpy import run_path
import sys

if __name__ == "__main__":
    runner = run_path(str(Path(__file__).resolve().with_name("run-native-probe.py")))
    sys.exit(runner["main"]("history-reference"))
