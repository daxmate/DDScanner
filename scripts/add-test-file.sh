#!/usr/bin/env bash
# 新增测试文件登记助手：建骨架 + 提醒登记契约表（不改生成物、不手改 pbxproj）。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  echo "用法：scripts/add-test-file.sh Tests/ContractTests/FooContractTests.swift" >&2
  exit 2
fi
case "$TARGET" in
  Tests/ContractTests/*) ;;
  *) echo "❌ 目前只支持在 Tests/ContractTests/ 下新增契约测试（其它测试走各 SPM 包）" >&2; exit 2 ;;
esac
if [[ -e "$TARGET" ]]; then
  echo "❌ 文件已存在，不覆盖：$TARGET" >&2
  exit 1
fi
mkdir -p "$(dirname "$TARGET")"
cat > "$TARGET" <<INNER
// 契约：<守什么语义>（见 docs/contract-register.md）
import Foundation
import Testing

@Suite("契约 · <语义>")
struct $(basename "$TARGET" .swift) {
    @Test("仓库当前无违规")
    func repositoryIsClean() {
        // TODO: 纯扫描实现
    }

    @Test("自证：注入违规必须被判红")
    func selfProof() {
        // TODO: 注入违规 → 必须红
    }
}
INNER
echo "✅ 已创建 $TARGET"
echo "⚠️ 还要做两件事：① 在 docs/contract-register.md 登记 ② 跑 swift test --package-path Tests"
