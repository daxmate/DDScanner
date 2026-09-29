#!/usr/bin/env bash
# G2 结构硬上限：唯一规则实现 = Tests/ContractTests/Support/StructuralBudgetRule.swift
# 用法：check-structural-budget.sh [check|selftest]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RULE="$ROOT/Tests/ContractTests/Support/StructuralBudgetRule.swift"
TOOL="$ROOT/scripts/structural-budget-tool.swift"
BIN="${TMPDIR:-/tmp}/ddscanner-structural-budget"
swiftc -parse-as-library -O -o "$BIN" "$RULE" "$TOOL"
MODE="${1:-check}"
case "$MODE" in
  check) exec "$BIN" "$ROOT" ;;
  selftest) exec "$BIN" --selftest ;;
  *) echo "用法：check-structural-budget.sh [check|selftest]" >&2; exit 2 ;;
esac
