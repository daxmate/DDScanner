# 架构与分层硬边界

## 目标形态

```
App/                    SwiftUI 应用 target（iOS 17+，iPhone + iPad），AppCompositionRoot.swift 是唯一装配点
Sources/DDScannerCore/   平台无关纯逻辑：几何、管线编排、日志、错误类型
Sources/DDScannerVision/ Apple 后端：Vision 边缘检测 + Core Image 透视校正
Sources/DDScannerDewarp/ 去畸变：抽象协议 + Core ML（UVDoc 网格模型）后端实现
Sources/DDScannerExport/ PDF / 图片导出
Resources/{zh-Hans,en}.lproj  本地化资源
Tests/ContractTests/     扫描型契约测试（可在 macOS 本地直接跑）
```

四个 `Sources/*` 都是**本地 SPM package**（`project.yml` 用 `packages.path` 指向），App target 消费其 product。

## 硬边界（写进 CI 门禁）

1. **`DDScannerCore` 只允许** `import Foundation` / `CoreGraphics` / `Accelerate`。
   **禁止** `UIKit` / `SwiftUI` / `Vision` / `CoreML` / `AVFoundation` / `CoreImage`。
   检查：`scripts/check-forbidden-imports.sh`。
2. **协议与实现分离**：Core 只声明协议（`DocumentDetecting` / `PerspectiveCorrecting` /
   `PageDewarping` / `PageExporting`）；Apple 与 Core ML 后端在各自模块实现。
3. **唯一装配点**：只有 `App/AppCompositionRoot.swift` 允许构造 `ScanEnvironment`。
   视图层一律从 `Environment` 取依赖，不得自行 `new` 实现。
   检查：`Tests/ContractTests/EnvironmentInjectionContractTests.swift`。
4. **生成物入库**：`DDScanner.xcodeproj` 由 `project.yml` 生成并入库（clone 后可直接打开）。
   **禁手改** `.xcodeproj`；改法 = 改 `project.yml` → `scripts/gen-project.sh`。
5. **结构硬上限**：单 Swift 文件 ≤ **600 行**；产品代码（`Sources/`、`App/`）**禁裸 `print(`**。
   检查：`scripts/check-structural-budget.sh`（无棘轮基线：从零起步，存量恒为 0）。

## 为什么 Core 必须平台无关（本项目的关键决定）

- **为了测试能脱离模拟器本地跑**：`cd Sources/DDScannerCore && swift test` 在本机直接通过，
  不需要起模拟器、不需要真机。相机/文档扫描强依赖真机，能留在本地跑的逻辑越多，
  反馈循环越短。
- 相机与文档扫描在模拟器上**无法取证**（无摄像头）；把纯逻辑（几何、单应、网格采样、
  管线编排）从平台 API 中剥离，等于把可自动化验证的面积最大化。
- 副产物：Core 的依赖闭包极小，未来若要做跨平台或命令行工具，可直接复用。

## 本轮（批 1）刻意不做

- 不实现相机采集、边缘检测实现、透视校正像素管线、去畸变推理、PDF 生成、任何 UI 页面。
- 各模块只放**最小可编译占位**（每个文件 ≤ 120 行，注释指向本文件）。

## 批 3：去畸变落地（UVDoc）

- **Core 新增两件事**（仍只依赖 Foundation / CoreGraphics）：`GridResampler`（归一化网格 → Float32
  重采样，含网格插值，越界 clamp）与 `GridPredicting` 协议（像素 → 归一化网格，模型的原生契约）。
  重采样必须留在 Swift 侧的精度依据，见 `Tools/ModelConvert/README.md`。
- **Dewarp 落地 Core ML 后端**：`CoreMLDewarpBackend` 装载 `Models/UVDocGrid_fp16.mlpackage` 并推理；
  模型缺失/加载失败**只抛错不崩**，组合根降级为 `nil`。
- **App 新增 DEBUG 自测页**：`App/Dev/`（`DewarpSelfTestView` + 运行器），入口在首页工具栏；
  用量与判读见 `docs/device-test-uvdoc.md`。该页只读 Environment，不构造实现。
- **仍未接管线**：`ScanFrame` 不含像素，`PageDewarping`（帧几何 → 网格）与像素型模型还差一层适配器；
  相机/拍摄/边缘检测/四角微调仍属后续批次。
