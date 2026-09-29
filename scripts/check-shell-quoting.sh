#!/usr/bin/env bash
# G10 静态门禁：shell 变量展开边界（变量引用紧跟非 ASCII 字节）
#
# 为什么：脚本里写「变量引用」后**紧跟非 ASCII 字节**（全角冒号、全角括号等多字节字符）时，
# 较新的 bash（5.x + UTF-8 locale）会把多字节字节并入变量名 → `set -u` 下报 unbound variable，
# 整段脚本失败；而 macOS 自带旧 bash（3.2.57）不重现该行为 —— 于是本地自验全绿、CI 才红。
# 修法一律是**花括号定界**：写 `${VAR}`，不要写裸的 `$VAR` 后直接接非 ASCII 字符。
#
# 判据：`$` + 变量名（[A-Za-z_][A-Za-z0-9_]*）+ 紧跟一个非 ASCII 字节（>= 0x80）→ 命中。
#   - 已经写成 `${VAR}` 的不命中（`$` 后面是 `{`）。
#   - 注释行**不豁免**：注释里的同类写法被复制粘贴进代码同样是隐患。
# 扫描范围：`scripts/*.sh`（仅顶层）与 `.github/workflows/*.yml`（仅顶层）。
# fail-closed：任一待扫目录不存在/不可读，或一个待扫文件都没找到 → 一律 exit 1。
#
# 用法：bash scripts/check-shell-quoting.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SCAN_DIRS="scripts .github/workflows"
for d in $SCAN_DIRS; do
  if [[ ! -d "$d" || ! -r "$d" ]]; then
    echo "❌ G10 fail-closed：待扫目录不存在或不可读 -> $d" >&2
    exit 1
  fi
done

files="$(find scripts .github/workflows -maxdepth 1 -type f \( -name '*.sh' -o -name '*.yml' \) | sort)"
if [[ -z "$files" ]]; then
  echo "❌ G10 fail-closed：一个待扫文件都没找到（scripts/*.sh 与 .github/workflows/*.yml）" >&2
  exit 1
fi

found=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  hits="$(perl -ne 'print "$ARGV:$.:$_" if /\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]/' "$f" || true)"
  if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits"
    found=1
  fi
done <<< "$files"

if [[ "$found" -ne 0 ]]; then
  echo "❌ G10：以上行的变量引用紧跟非 ASCII 字节 —— 请改用花括号定界（形如 \${VAR}），避免 bash 5 下报 unbound variable" >&2
  exit 1
fi

echo "✅ G10：scripts/*.sh 与 .github/workflows/*.yml 未发现「变量引用紧跟非 ASCII 字节」的写法"
