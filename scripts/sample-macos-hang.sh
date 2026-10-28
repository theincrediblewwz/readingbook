#!/bin/bash
# Local-only process sampling. Does not quit the app or read its book library.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "此工具需要 macOS。" >&2
  exit 1
fi
PIDS="$(pgrep -x ReadingBook || true)"
if [[ -z "$PIDS" ]]; then
  echo "ReadingBook 没有运行；请先打开应用。" >&2
  exit 1
fi
if [[ "$PIDS" == *$'\n'* ]]; then
  echo "检测到多个 ReadingBook 进程，请关闭多余测试实例再采样。" >&2
  exit 1
fi
umask 077
mkdir -p logs
OUTPUT="$(mktemp -d "$PWD/logs/mac-sample-$(date '+%Y%m%d-%H%M%S').XXXXXX")"
METRICS_PID=""
cleanup() {
  if [[ -n "$METRICS_PID" ]]; then
    kill "$METRICS_PID" 2>/dev/null || true
    wait "$METRICS_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM
{
  date '+%Y-%m-%d %H:%M:%S %z'
  sw_vers
  sysctl -n hw.model hw.memsize
  ps -p "$PIDS" -o pid,etime,%cpu,%mem,rss,vsize,state,command
} > "$OUTPUT/context.txt"
(
  while kill -0 "$PIDS" 2>/dev/null; do
    date '+%Y-%m-%d %H:%M:%S %z'
    ps -p "$PIDS" -o pid,etime,%cpu,%mem,rss,vsize,state
    sleep 1
  done
) > "$OUTPUT/metrics.txt" &
METRICS_PID=$!

echo "正在采集 ReadingBook 主线程及其他线程，约 10 秒。"
echo "请保留卡住的应用，不要强制退出。"
/usr/bin/sample "$PIDS" 10 10 -file "$OUTPUT/process.sample.txt"
cleanup
METRICS_PID=""
if ! /usr/bin/log show --last 5m --style compact --predicate "processIdentifier == $PIDS" > "$OUTPUT/system.log" 2>&1; then
  echo "系统日志读取失败；进程采样仍已保留。" >&2
fi
awk '
  /Thread_[^ ]+.*(Main Thread|com.apple.main-thread)/ { capture = 1 }
  capture && /^[[:space:]]*[0-9]+ Thread_/ && !/(Main Thread|com.apple.main-thread)/ { exit }
  capture { print }
' "$OUTPUT/process.sample.txt" > "$OUTPUT/main-thread.txt"
if [[ ! -s "$OUTPUT/main-thread.txt" ]]; then
  echo "无法自动提取主线程；完整采样已保留在 $OUTPUT/process.sample.txt。" >&2
  exit 1
fi
echo "采样已保存：$OUTPUT"
echo "完整调用栈：process.sample.txt；主线程：main-thread.txt；CPU/内存：metrics.txt；系统日志：system.log。"
echo "这些诊断仅保存在本机，可能包含本机路径；不会上传或修改书库。"
