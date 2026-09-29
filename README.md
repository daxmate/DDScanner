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

## License

Apache-2.0 — see [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md). Third-party notices
(PaddleOCR / UVDoc and their papers) are listed in `NOTICE.md`.

## 中文速览

DDScanner 是开源的 iOS 文档扫描 App（iOS 17+，Apache-2.0）。当前提交只包含**立项基线**：
纪律文档、9 条可执行门禁、XcodeGen 工程骨架、四个 SPM 模块与契约测试骨架，**尚未实现任何业务功能**。
本地只做编译级验证（禁起模拟器），Core 模块与契约测试可在本机 `swift test` 直接跑通。

贡献前请先读 `AGENTS.md`（门禁与红线）与 `docs/architecture.md`（分层硬边界）。
