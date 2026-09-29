#!/usr/bin/env bash
# 统一构建入口（G9）：所有本地/CI 构建必须走本脚本，禁止裸 xcodebuild。
# DerivedData 按仓库隔离（默认 .build/DerivedData，已 gitignore）；如配了共享 SPM 缓存则注入。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${DDSCANNER_DERIVED_DATA:-$ROOT/.build/DerivedData}"
mkdir -p "$DERIVED_DATA"
EXTRA=(-derivedDataPath "$DERIVED_DATA")
if [[ -n "${DDSCANNER_SPM_CACHE:-}" ]]; then
  EXTRA+=(-clonedSourcePackagesDirPath "$DDSCANNER_SPM_CACHE")
fi
echo "▶ xcodebuild $* ${EXTRA[*]}"
exec xcodebuild "$@" "${EXTRA[@]}"
