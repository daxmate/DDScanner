#!/usr/bin/env bash
# G9：CI 与脚本必须走统一构建入口 scripts/xcbuild.sh，不得直接调用构建工具。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
SELF="scripts/check-build-entry.sh"
PATTERN="xcode""build"
hits="$(grep -rn --include='*.yml' --include='*.yaml' --include='*.sh' -e "$PATTERN" .github scripts 2>/dev/null \
  | grep -v "^$(printf '%s' "$SELF" | sed 's#\.#\\.#g'):" \
  | grep -v '^scripts/xcbuild.sh:' || true)"
if [[ -n "$hits" ]]; then
  echo "❌ 发现绕过统一入口的裸调用（必须走 scripts/xcbuild.sh）：" >&2
  echo "$hits" >&2
  exit 1
fi
echo "✅ 统一构建入口：未发现裸调用"
