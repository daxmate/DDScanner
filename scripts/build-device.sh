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
DEVICE_LIST_TIMEOUT_SECONDS=20
# devicectl 列表命令的硬超时：部分机器上它永不退出，绝不能让它卡住整个脚本。
DEVICECTL_LIST_TIMEOUT_SECONDS=30

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

# 列出真机条目（每行制表符分隔「状态 \t 名称 \t UDID」）。
#   状态 device  = 运行本脚本的这台 Mac 上可直接安装 / 启动
#   状态 offline = 已配对但本机不可达（设备连在别的 Mac 上，或未插到本机）
# 可达性第一口径：devicectl JSON（见下方 detect_device_via_devicectl）。devicectl 的隧道是按需
# 建立的：xctrace 把设备列在「Devices Offline」不代表 devicectl 装不上，两者冲突时以 devicectl 为准。
# 本函数只做 devicectl 不可用时的回退：`devicectl list devices` 在部分机器上会挂死（内部服务
# 不返回，命令一直不退出），此时回退 xctrace 并明确提示「可能漏判」。
# 只解析 `== Devices ==` 段（跳过该段第一行——运行本脚本的 Mac 自己）与 `== Devices Offline ==` 段；
# 完全忽略 `== Simulators ==`（禁模拟器）。
list_device_entries() {
  local out_file="${TMPDIR:-/tmp}/ddscanner-xctrace-$$.txt"
  if ! run_with_timeout_to_file "${DEVICE_LIST_TIMEOUT_SECONDS}" "${out_file}" xcrun xctrace list devices; then
    echo "❌ 无法列出真机（xcrun xctrace list devices 失败或超时 ${DEVICE_LIST_TIMEOUT_SECONDS}s）" >&2
    return 1
  fi
  local section=""
  local first_in_devices=0
  local line head name udid
  while IFS= read -r line; do
    case "${line}" in
      "== Devices ==")
        section="devices"
        first_in_devices=1
        continue
        ;;
      "== Devices Offline ==")
        section="offline"
        continue
        ;;
      "== Simulators ==")
        section="simulators"
        continue
        ;;
      "== "*)
        section="other"
        continue
        ;;
    esac
    # 跳过空行
    if [[ -z "${line//[[:space:]]/}" ]]; then
      continue
    fi
    # 只保留 Devices / Devices Offline 两段
    if [[ "${section}" != "devices" && "${section}" != "offline" ]]; then
      continue
    fi
    # `== Devices ==` 段第一行是运行本脚本的 Mac 自己，跳过
    if [[ "${section}" == "devices" && "${first_in_devices}" -eq 1 ]]; then
      first_in_devices=0
      continue
    fi
    # 行格式：`名称 (iOS x.y) (UDID)`（末括号内是设备 UDID）
    if [[ "${line}" =~ ^(.*[^[:space:]])[[:space:]]+\(([0-9A-Fa-f-]{16,})\)[[:space:]]*$ ]]; then
      head="${BASH_REMATCH[1]}"
      udid="${BASH_REMATCH[2]}"
    else
      continue
    fi
    # 去掉名称后可能跟随的系统版本括号，如 `(iOS 26.6.2)`
    if [[ "${head}" =~ ^(.*[^[:space:]])[[:space:]]+\([^()]*\)$ ]]; then
      name="${BASH_REMATCH[1]}"
    else
      name="${head}"
    fi
    if [[ "${section}" == "devices" ]]; then
      printf 'device\t%s\t%s\n' "${name}" "${udid}"
    else
      printf 'offline\t%s\t%s\n' "${name}" "${udid}"
    fi
  done < "${out_file}"
}

# 用 devicectl 检测可用真机：成功时 stdout 打印一个 UDID；
# 没有可用设备返回 1（stderr 给出逐台跳过原因）；devicectl 本身不可用（超时 / 失败 / 无 JSON）返回 2。
detect_device_via_devicectl() {
  local json_file="${TMPDIR:-/tmp}/ddscanner-devicectl-$$.json"
  rm -f "${json_file}"
  local rc=0
  run_with_timeout_to_file "${DEVICECTL_LIST_TIMEOUT_SECONDS}" /dev/null \
    xcrun devicectl list devices --json-output "${json_file}" || rc=$?
  if [[ "${rc}" -eq 124 ]]; then
    echo "⚠️ devicectl list devices 超过 ${DEVICECTL_LIST_TIMEOUT_SECONDS}s 未返回（已强杀）" >&2
    rm -f "${json_file}"
    return 2
  fi
  if [[ "${rc}" -ne 0 || ! -s "${json_file}" ]]; then
    echo "⚠️ devicectl list devices 执行失败（退出码 ${rc}，或未产出 JSON）" >&2
    rm -f "${json_file}"
    return 2
  fi

  local udid=""
  if udid="$(python3 "${ROOT}/scripts/detect-device.py" "${json_file}")" && [[ -n "${udid}" ]]; then
    rm -f "${json_file}"
    printf '%s\n' "${udid}"
    return 0
  fi

  echo "❌ devicectl 未发现可用于安装的 iOS 真机（逐台跳过原因）：" >&2
  python3 "${ROOT}/scripts/detect-device.py" --explain "${json_file}" >/dev/null || true
  rm -f "${json_file}"
  return 1
}

# 解析目标真机：--device 优先；否则以 devicectl 为准，devicectl 不可用时回退 xctrace（可能漏判）。
# 失败时把情形分开报错，便于自查（离线设备 / 完全没有设备 / 多台）。
resolve_device() {
  if [[ -n "${DEVICE}" ]]; then
    printf '%s' "${DEVICE}"
    return 0
  fi

  local rc=0 udid=""
  udid="$(detect_device_via_devicectl)" || rc=$?
  if [[ "${rc}" -eq 0 && -n "${udid}" ]]; then
    echo "▶ 设备检测：devicectl（可达性以 devicectl JSON 为准）" >&2
    printf '%s\n' "${udid}"
    return 0
  fi
  if [[ "${rc}" -eq 1 ]]; then
    return 1
  fi

  echo "⚠️ 本机 devicectl 不可用（超时或失败），已回退 xctrace —— 可能漏判可达设备；建议在正常终端里手动指定 --device <udid>" >&2

  local entries
  if ! entries="$(list_device_entries)"; then
    return 1
  fi
  local online_count offline_count
  online_count="$(printf '%s\n' "${entries}" | awk -F'\t' '$1 == "device" { n++ } END { print n + 0 }')"
  offline_count="$(printf '%s\n' "${entries}" | awk -F'\t' '$1 == "offline" { n++ } END { print n + 0 }')"

  if [[ "${online_count}" -eq 0 ]]; then
    if [[ "${offline_count}" -gt 0 ]]; then
      echo "❌ 未检测到本机可达的真机（本机 = 运行本脚本的这台 Mac）" >&2
      echo "   发现以下已配对的离线设备：" >&2
      printf '%s\n' "${entries}" | awk -F'\t' '$1 == "offline" { printf "     - %s（UDID %s）\n", $2, $3 }' >&2
      echo "   这些设备已配对，但在运行本脚本的这台 Mac 上不可达 → 把设备插到这台 Mac，或改用有设备的机器，或 --device <udid|名称>" >&2
    else
      echo "❌ 未检测到任何真机。确认设备已插到本机、已解锁并点『信任』。" >&2
    fi
    return 1
  fi

  if [[ "${online_count}" -gt 1 ]]; then
    echo "❌ 检测到多台本机可达真机，请用 --device <udid|名称> 指定其一：" >&2
    printf '%s\n' "${entries}" | awk -F'\t' '$1 == "device" { printf "     - %s（UDID %s）\n", $2, $3 }' >&2
    return 1
  fi

  printf '%s\n' "${entries}" | awk -F'\t' '$1 == "device" { print $3 }'
}

# 提前解析目标真机：装不到设备就没必要跑构建，也避免长时间构建后才发现设备不可达。
TARGET_DEVICE=""
if [[ "${DO_INSTALL}" -eq 1 ]]; then
  TARGET_DEVICE="$(resolve_device)" || exit 1
  echo "▶ 目标真机：${TARGET_DEVICE}"
fi

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

if [[ "${DO_INSTALL}" -eq 1 ]]; then
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
