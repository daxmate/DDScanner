#!/usr/bin/env bash
# G1 零编译警告：走统一构建入口，命中源码/工程级 warning 即失败。
# 用法：check-zero-warnings.sh [action...]
#   - build / build-for-testing …：走统一入口 scripts/xcbuild.sh -scheme DDScanner（默认 build；iOS Simulator 通用目标）
#   - packages：SPM 包与测试 target（`swift build --build-tests`，debug + release）零警告
#
# 为什么有 packages：Xcode scheme 构建只编 scheme 内的 App/库 target，**编不到 SPM 测试 target**
# （DDScannerCoreTests / DDScannerDewarpTests / ContractTests）。
# 批 8 的 `Thread.isMainThread` 告警（Swift 6 起为 error）正是从这条缝漏过 CI 的。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
ACTION="${1:-build}"
shift || true

if [[ "${ACTION}" == "packages" ]]; then
  # 五个 SPM 包全扫（防掩盖）：三个带测试 target（Core / Dewarp / Tests）+ 两个仅库包（Export / Vision）。
  PACKAGES=(
    Sources/DDScannerCore
    Sources/DDScannerDewarp
    Sources/DDScannerExport
    Sources/DDScannerVision
    Tests
  )
  CONFIGS=(debug release)
  LOG_DIR="${TMPDIR:-/tmp}/ddscanner-packages-$$"
  mkdir -p "${LOG_DIR}"
  echo "▶ SPM 包与测试 target 零警告：日志目录 ${LOG_DIR}"
  failed=0
  for CONFIG in "${CONFIGS[@]}"; do
    for PACKAGE in "${PACKAGES[@]}"; do
      NAME="$(basename "${PACKAGE}")"
      LOG="${LOG_DIR}/${NAME}-${CONFIG}.log"
      # release 下 `swift build` 不给库 target 传 -enable-testing，`@testable import` 会编译失败；
      # 手动补上（`swift test` 自带该行为），只影响可测性、不改变诊断口径。
      if [[ "${CONFIG}" == "release" ]]; then
        BUILD=(swift build --build-tests -c release --package-path "${PACKAGE}" -Xswiftc -enable-testing)
      else
        BUILD=(swift build --build-tests -c debug --package-path "${PACKAGE}")
      fi
      if ! "${BUILD[@]}" > "${LOG}" 2>&1; then
        echo "❌ ${PACKAGE}（${CONFIG}）构建失败（日志尾部）：" >&2
        tail -40 "${LOG}" >&2
        failed=1
        continue
      fi
      if ! grep -q 'Build complete!' "${LOG}"; then
        echo "❌ ${PACKAGE}（${CONFIG}）日志里没有 'Build complete!' —— 未产出预期成功信号（fail-closed）" >&2
        tail -40 "${LOG}" >&2
        failed=1
        continue
      fi
      hits="$(grep -E 'warning:' "${LOG}" || true)"
      if [[ -n "${hits}" ]]; then
        echo "❌ ${PACKAGE}（${CONFIG}）发现编译警告：" >&2
        echo "${hits}" >&2
        failed=1
      fi
    done
  done
  if [[ "${failed}" -ne 0 ]]; then
    exit 1
  fi
  echo "✅ SPM 包与测试 target 构建成功且零编译警告（debug + release）"
  exit 0
fi

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
