#!/usr/bin/env bash
# 真机构建入口：生成工程（可选）→ 真机（generic/platform=iOS）构建 → 可选安装 / 启动。
#
# 与 CI 的区别：CI 只做「编译级验证」（模拟器通用目标 + 关闭签名）；本脚本面向真机，
# 经统一构建入口 scripts/xcbuild.sh（G9：禁止在脚本里直接调用构建工具）。
# 签名沿用工程既有设置（project.yml 的 DEVELOPMENT_TEAM），自动签名走 -allowProvisioningUpdates，
# 不硬编码 team / 证书。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

APP_NAME="DDScanner"
APP_BUNDLE_ID="com.daxmate.DDScanner"
DEVICECTL_TIMEOUT_SECONDS=20

CONFIG="Debug"
RUN_GEN=1
DO_INSTALL=0
DO_LAUNCH=0
DEVICE=""

usage() {
  cat <<'EOF'
用法：scripts/build-device.sh [选项]

真机构建（iOS 17+）。默认先重新生成工程，再构建 Debug 真机包。

选项：
  --debug               构建 Debug 配置（默认）
  --release             构建 Release 配置
  --device <udid|名称>   指定目标真机（安装 / 启动时用）
  --install             构建后安装到已连接真机
  --launch              安装后启动 App（隐含 --install）
  --no-gen              跳过 scripts/gen-project.sh，直接用现有工程构建
  -h, --help            显示本帮助

产物：.build/DerivedData/Build/Products/<Debug|Release>-iphoneos/DDScanner.app
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1}" in
    --debug) CONFIG="Debug"; shift ;;
    --release) CONFIG="Release"; shift ;;
    --device)
      if [[ $# -lt 2 ]]; then
        echo "❌ --device 需要参数（udid 或名称）" >&2
        exit 2
      fi
      DEVICE="${2}"
      shift 2
      ;;
    --install) DO_INSTALL=1; shift ;;
    --launch) DO_LAUNCH=1; DO_INSTALL=1; shift ;;
    --no-gen) RUN_GEN=0; shift ;;
    -h | --help) usage; exit 0 ;;
    *)
      echo "❌ 未知参数：${1}" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# 在限定秒数内运行命令，stdout 落盘到指定文件（不用命令替换：真机工具的辅助进程
# 会一直占住管道写端，导致 `$( )` 读不到 EOF 而假死）；超时杀进程并返回 124。
run_with_timeout_to_file() {
  local seconds="${1}"
  local out_file="${2}"
  shift 2
  : > "${out_file}"
  "${@}" > "${out_file}" 2>/dev/null &
  local pid=$!
  local waited=0
  while kill -0 "${pid}" 2>/dev/null; do
    if [[ "${waited}" -ge "${seconds}" ]]; then
      kill -9 "${pid}" 2>/dev/null || true
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "${pid}"
}

# 打印当前「已连接」真机的 identifier（每行一个）。
connected_device_ids() {
  local out_file="${TMPDIR:-/tmp}/ddscanner-devices-$$.txt"
  if ! run_with_timeout_to_file "${DEVICECTL_TIMEOUT_SECONDS}" "${out_file}" xcrun devicectl list devices; then
    echo "❌ 无法列出真机（xcrun devicectl list devices 失败或超时 ${DEVICECTL_TIMEOUT_SECONDS}s）" >&2
    return 1
  fi
  # awk：找出 36 位 UUID 字段，且其后一列状态为 connected。
  # shellcheck disable=SC2016
  awk '
    {
      for (i = 1; i <= NF; i++) {
        if (length($i) == 36 && $i ~ /^[0-9A-Fa-f]+-[0-9A-Fa-f]+-[0-9A-Fa-f]+-[0-9A-Fa-f]+-[0-9A-Fa-f]+$/ && $(i + 1) == "connected") {
          print $i
        }
      }
    }' "${out_file}"
}

# 解析目标真机：--device 优先；否则要求恰有一台已连接真机。
resolve_device() {
  if [[ -n "${DEVICE}" ]]; then
    printf '%s' "${DEVICE}"
    return 0
  fi
  local ids
  if ! ids="$(connected_device_ids)"; then
    return 1
  fi
  local count=0
  if [[ -n "${ids}" ]]; then
    count="$(printf '%s\n' "${ids}" | grep -c .)"
  fi
  if [[ "${count}" -eq 0 ]]; then
    echo "❌ 未检测到已连接的真机，请连接设备或用 --device <udid|名称> 指定" >&2
    return 1
  fi
  if [[ "${count}" -gt 1 ]]; then
    echo "❌ 检测到多台已连接真机，请用 --device <udid> 指定其一：" >&2
    printf '%s\n' "${ids}" >&2
    return 1
  fi
  printf '%s' "${ids}"
}

if [[ "${RUN_GEN}" -eq 1 ]]; then
  echo "▶ 生成工程（scripts/gen-project.sh）"
  bash scripts/gen-project.sh
fi

DERIVED_DATA="${DDSCANNER_DERIVED_DATA:-${ROOT}/.build/DerivedData}"
APP_PATH="${DERIVED_DATA}/Build/Products/${CONFIG}-iphoneos/${APP_NAME}.app"

echo "▶ 真机构建：配置 ${CONFIG}，目标 generic/platform=iOS"
bash scripts/xcbuild.sh build -project DDScanner.xcodeproj -scheme DDScanner -configuration "${CONFIG}" -destination 'generic/platform=iOS' -allowProvisioningUpdates

if [[ ! -d "${APP_PATH}" ]]; then
  echo "❌ 未找到构建产物：${APP_PATH}" >&2
  exit 1
fi

COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
DIRTY=""
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  DIRTY="（工作区有未提交改动）"
fi

echo "✅ 构建完成"
echo "   commit：${COMMIT}${DIRTY}"
echo "   配置  ：${CONFIG}"
echo "   产物  ：${APP_PATH}"

TARGET_DEVICE=""
if [[ "${DO_INSTALL}" -eq 1 ]]; then
  TARGET_DEVICE="$(resolve_device)" || exit 1
  echo "▶ 安装到真机：${TARGET_DEVICE}"
  xcrun devicectl device install app --device "${TARGET_DEVICE}" "${APP_PATH}"
fi

if [[ "${DO_LAUNCH}" -eq 1 ]]; then
  echo "▶ 启动 App：${APP_BUNDLE_ID}"
  xcrun devicectl device process launch --device "${TARGET_DEVICE}" "${APP_BUNDLE_ID}"
fi

echo ""
echo "下一步："
echo "  - 安装到真机：bash scripts/build-device.sh --install [--device <udid>]"
echo "  - 安装并启动：bash scripts/build-device.sh --launch [--device <udid>]"
echo "  - 真机验收清单：docs/device-acceptance-checklist.md"
