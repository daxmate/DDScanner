#!/usr/bin/env bash
# 分层硬边界：DDScannerCore 只允许 Foundation / CoreGraphics / Accelerate。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
CORE="Sources/DDScannerCore/Sources"
FORBIDDEN='UIKit|SwiftUI|Vision|CoreML|AVFoundation|CoreImage'
hits="$(grep -rnE "^ *import +($FORBIDDEN)" "$CORE" 2>/dev/null || true)"
if [[ -n "$hits" ]]; then
  echo "❌ DDScannerCore 出现平台依赖（见 docs/architecture.md）：" >&2
  echo "$hits" >&2
  exit 1
fi
echo "✅ 分层边界：DDScannerCore 未引入 UIKit/SwiftUI/Vision/CoreML"
