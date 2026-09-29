#!/usr/bin/env bash
# G7 依赖许可扫描：白名单外许可即红；黑名单模型（D2Dewarp / DRCCBI / DocTr）出现即红。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
WHITELIST="scripts/dependency-license-whitelist.tsv"
ALLOWED='^(MIT|Apache-2\.0|BSD-2-Clause|BSD-3-Clause)$'
BANNED='D2Dewarp|DRCCBI|DocTr'
status=0

# 1) 三方依赖声明：Package.swift / project.yml 的远程依赖（本地 path 依赖不计入）
declared="$(grep -rhoE '\.package\(url: *"[^"]+"' --include='Package.swift' . 2>/dev/null \
  | sed -E 's/.*url: *"//; s/"$//' | sort -u || true)"
if [[ -n "$declared" ]]; then
  while IFS= read -r url; do
    [[ -z "$url" ]] && continue
    name="$(basename "$url" .git)"
    if grep -qE "^${name}[[:space:]]" "$WHITELIST"; then
      license="$(grep -E "^${name}[[:space:]]" "$WHITELIST" | head -1 | cut -f2)"
      if ! printf '%s' "$license" | grep -qE "$ALLOWED"; then
        echo "❌ 依赖 $name 许可不在允许集（$license）" >&2; status=1
      else
        echo "✅ 依赖 $name 许可 $license 已登记"
      fi
    else
      echo "❌ 依赖未登记在白名单：$url（$WHITELIST）" >&2; status=1
    fi
  done <<< "$declared"
fi

# 2) 黑名单模型 / 库
banned_hits="$(grep -rniE "$BANNED" --include='*.swift' --include='Package.swift' --include='project.yml' --include='*.pbxproj' Sources App Tests project.yml 2>/dev/null || true)"
if [[ -n "$banned_hits" ]]; then
  echo "❌ 命中黑名单模型/库（许可不明或不可再分发）：" >&2
  echo "$banned_hits" >&2
  status=1
fi

# 3) 白名单自身完整性：每行必须有 3 列
while IFS= read -r line; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  columns="$(printf '%s' "$line" | awk -F'\t' '{print NF}')"
  if [[ "$columns" -lt 3 ]]; then
    echo "❌ 白名单行缺理由列：$line" >&2; status=1
  fi
done < "$WHITELIST"

if [[ "$status" -eq 0 ]]; then
  echo "✅ 依赖许可扫描通过（声明依赖 $(printf '%s' "$declared" | grep -c . || true) 个，黑名单 0 命中）"
fi
exit "$status"
