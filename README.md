# DDScanner

An open-source document scanner for iOS 17+ (iPhone & iPad), built on Apple's native vision
pipeline (Vision edge detection + Core Image perspective correction) with a pluggable
**UVDoc** Core ML backend for non-linear page dewarping.

> Status: **project baseline only.** This repository currently contains the discipline
> documents, executable gates, an XcodeGen project skeleton, four SPM modules and the
> contract-test scaffolding. No scanning feature is implemented yet.

## Layout

| Path | Role |
|---|---|
| `Sources/DDScannerCore/` | Platform-independent logic (geometry, pipeline, logging, errors). `swift test` runs it locally, no simulator. |
| `Sources/DDScannerVision/` | Vision edge detection + Core Image perspective correction (Apple backend). |
| `Sources/DDScannerDewarp/` | Dewarp model protocol + Core ML backend (UVDoc). |
| `Sources/DDScannerExport/` | PDF / image export. |
| `App/` | SwiftUI app target (iOS 17+), single composition root in `App/AppCompositionRoot.swift`. |
| `Tests/ContractTests/` | Scan-based contract tests (run with `swift test --package-path Tests`). |
| `docs/` | Architecture, model supply chain, acceptance, logging, contract register. |

## Build & test

```bash
scripts/gen-project.sh                                   # regenerate DDScanner.xcodeproj
scripts/xcbuild.sh build -scheme DDScanner \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
swift test --package-path Sources/DDScannerCore         # Core unit tests (no simulator)
swift test --package-path Tests                         # contract tests (no simulator)
bash scripts/check-structural-budget.sh check           # structural budget gate
bash scripts/check-dependency-licenses.sh                # license gate
```

Local simulator runs are deliberately **not** part of the workflow: UI and performance
verification happens on real devices (`docs/device-acceptance-checklist.md`).

## 真机构建 / 安装

真机（iOS 17+）构建走 `scripts/build-device.sh`，内部经统一构建入口 `scripts/xcbuild.sh`（G9）。
签名沿用工程既有设置（`project.yml` 的 `DEVELOPMENT_TEAM`），自动签名由 `-allowProvisioningUpdates`
处理，**不硬编码 team / 证书**。

```bash
bash scripts/build-device.sh                      # 生成工程 + 构建 Debug 真机包
bash scripts/build-device.sh --release --no-gen   # 跳过生成，构建 Release
bash scripts/build-device.sh --install            # 构建后安装到唯一已连接真机
bash scripts/build-device.sh --launch             # 安装后启动 App（隐含 --install）
bash scripts/build-device.sh --device <udid|名称> --install   # 指定真机
```

- 产物：`.build/DerivedData/Build/Products/<Debug|Release>-iphoneos/DDScanner.app`（绝对路径由脚本打印）。
- `--install` / `--launch` 未给 `--device` 时自动取**唯一**已连接真机；0 台或多台会明确报错并列出候选。
- 与 CI 的区别：CI 只做**编译级验证**（模拟器通用目标 + 关闭签名）；本脚本面向**真机**
  （`generic/platform=iOS`），用于装到设备上做 UI / 性能验收（见 `docs/device-acceptance-checklist.md`）。

## License

Apache-2.0 — see [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md). Third-party notices
(PaddleOCR / UVDoc and their papers) are listed in `NOTICE.md`.

## 中文速览

DDScanner 是开源的 iOS 文档扫描 App（iOS 17+，Apache-2.0）。当前提交只包含**立项基线**：
纪律文档、9 条可执行门禁、XcodeGen 工程骨架、四个 SPM 模块与契约测试骨架，**尚未实现任何业务功能**。
本地只做编译级验证（禁起模拟器），Core 模块与契约测试可在本机 `swift test` 直接跑通。

贡献前请先读 `AGENTS.md`（门禁与红线）与 `docs/architecture.md`（分层硬边界）。
