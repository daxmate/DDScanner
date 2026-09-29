#!/usr/bin/env bash
# G1 零编译警告：走统一构建入口，命中源码/工程级 warning 即失败。
# 用法：check-zero-warnings.sh [action...]（默认 build -scheme DDScanner，iOS Simulator 通用目标）
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
ACTION="${1:-build}"
shift || true
LOG="${TMPDIR:-/tmp}/ddscanner-build-$$.log"
echo "▶ 构建日志：$LOG"
if ! bash scripts/xcbuild.sh "$ACTION" -scheme DDScanner \
  -destination "${DDSCANNER_DESTINATION:-generic/platform=iOS Simulator}" \
  CODE_SIGNING_ALLOWED=NO "$@" > "$LOG" 2>&1; then
  echo "❌ 构建失败（日志尾部）：" >&2
  tail -40 "$LOG" >&2
  exit 1
fi
if ! grep -q 'BUILD SUCCEEDED\|TEST BUILD SUCCEEDED' "$LOG"; then
  echo "❌ 未在日志中看到成功标记（BUILD SUCCEEDED / TEST BUILD SUCCEEDED）" >&2
  tail -40 "$LOG" >&2
  exit 1
fi
hits="$(grep -E 'warning:' "$LOG" | grep -vE 'Metadata extraction skipped' || true)"
if [[ -n "$hits" ]]; then
  echo "❌ 发现编译警告：" >&2
  echo "$hits" >&2
  exit 1
fi
echo "✅ 构建成功且零编译警告"
