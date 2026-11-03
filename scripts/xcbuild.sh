#!/usr/bin/env bash
# 统一构建入口（G9）：所有本地/CI 构建必须走本脚本，禁止裸 xcodebuild。
# 产物统一到仓库 build/：中间产物 build/DerivedData，成品 build/Products/<sdk>/<Config>/；
# 如配了共享 SPM 缓存则注入。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${DDSCANNER_DERIVED_DATA:-$ROOT/build/DerivedData}"
mkdir -p "$DERIVED_DATA"
EXTRA=(-derivedDataPath "$DERIVED_DATA")
if [[ -n "${DDSCANNER_SPM_CACHE:-}" ]]; then
  EXTRA+=(-clonedSourcePackagesDirPath "$DDSCANNER_SPM_CACHE")
fi
echo "▶ xcodebuild $* ${EXTRA[*]}"
xcodebuild "$@" "${EXTRA[@]}" || exit $?

# 成品统一落盘：仅 build 动作（build-for-testing 等不产 .app）。
ACTION="${1:-build}"
if [[ "$ACTION" != "build" ]]; then
  exit 0
fi

# 从参数推断配置与 SDK：xcodebuild 的产物目录形如 <Config>-<sdk>。
CONFIG="Debug"
SDK=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    -configuration) CONFIG="${args[$((i + 1))]:-Debug}" ;;
    -configuration=*) CONFIG="${args[$i]#-configuration=}" ;;
    -sdk) SDK="${args[$((i + 1))]:-}" ;;
    -sdk=*) SDK="${args[$i]#-sdk=}" ;;
    -destination)
      case "${args[$((i + 1))]:-}" in
        *iOS\ Simulator*) SDK="iphonesimulator" ;;
        *iOS*) SDK="iphoneos" ;;
        *macOS*) SDK="macosx" ;;
      esac
      ;;
    -destination=*)
      case "${args[$i]}" in
        *iOS\ Simulator*) SDK="iphonesimulator" ;;
        *iOS*) SDK="iphoneos" ;;
        *macOS*) SDK="macosx" ;;
      esac
      ;;
  esac
done

if [[ -z "$SDK" ]]; then
  echo "⚠️ 未能从参数推断 SDK，跳过成品复制（DerivedData：${DERIVED_DATA}）" >&2
  exit 0
fi

PRODUCTS_SRC="$DERIVED_DATA/Build/Products/${CONFIG}-${SDK}"
PRODUCTS_DEST="$ROOT/build/Products/${SDK}/${CONFIG}"
copied=0
for app in "$PRODUCTS_SRC"/*.app; do
  [[ -d "$app" ]] || continue
  mkdir -p "$PRODUCTS_DEST"
  name="$(basename "$app")"
  ditto "$app" "$PRODUCTS_DEST/$name"
  echo "✅ 成品：$PRODUCTS_DEST/$name"
  copied=1
done
if [[ "$copied" -eq 0 ]]; then
  echo "⚠️ 未找到可复制的 .app：$PRODUCTS_SRC" >&2
fi
