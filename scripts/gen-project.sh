#!/usr/bin/env bash
# 重新生成 DDScanner.xcodeproj（生成物一并入库，见 docs/architecture.md）。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "❌ 缺少 xcodegen（brew install xcodegen）" >&2
  exit 1
fi
xcodegen generate --spec project.yml --project .
echo "✅ 已生成 ${ROOT}/DDScanner.xcodeproj"
