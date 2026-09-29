#!/usr/bin/env bash
# G4 精神（测试信号 fail-closed）：确认 `swift test` 真的执行了预期数量的用例。
#
# 为什么要它：`swift test` 在「一条用例都没跑」时退出码仍是 0 ——
#   ① `--filter` 匹配 0 条用例（批 1 教训）；
#   ② 测试 target 被改名 / 包内没有测试 target / 扫不到用例文件。
#   只看退出码 = 假绿。本脚本在日志里找 swift-testing 的 `Test run with N tests` 行，
#   取不到、或 N 小于下限，一律 exit 1（fail-closed）。
#
# 用法：check-test-signal.sh <测试日志文件> <最少用例数> [标签]
set -euo pipefail

LOG="${1:?用法：check-test-signal.sh <日志文件> <最少用例数> [标签]}"
MINIMUM="${2:?用法：check-test-signal.sh <日志文件> <最少用例数> [标签]}"
LABEL="${3:-swift test}"

if [[ ! -f "$LOG" ]]; then
  echo "❌ ${LABEL}：找不到测试日志 $LOG" >&2
  exit 1
fi

count="$(grep -oE 'Test run with [0-9]+ tests' "$LOG" | tail -1 | grep -oE '[0-9]+' || true)"
if [[ -z "${count:-}" ]]; then
  echo "❌ ${LABEL}：日志里没有 'Test run with N tests' 行 —— 测试没跑起来（fail-closed）" >&2
  echo "---- 日志尾部 ----" >&2
  tail -n 20 "$LOG" >&2
  exit 1
fi
if (( count < MINIMUM )); then
  echo "❌ ${LABEL}：实际只跑了 $count 条用例，少于下限 $MINIMUM —— 疑似测试被静默跳过" >&2
  exit 1
fi
echo "✅ ${LABEL}：实际跑了 $count 条用例（下限 ${MINIMUM}）"
