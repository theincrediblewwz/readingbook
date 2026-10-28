#!/bin/bash
cd "$(dirname "$0")" || exit 1
/bin/bash scripts/sample-macos-hang.sh
RESULT=$?
echo
read -r -p "按回车关闭此窗口…" _
exit "$RESULT"
