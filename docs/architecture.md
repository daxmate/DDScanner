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

## 批 7：性能（真机首测超标项）

- **重采样向量化**：`GridResampler.resample` 的实现改为 `AcceleratedGridResampler`（Accelerate / vDSP，
  仍 Float32、越界 clamp、`align_corners=True` 语义不变）；旧标量实现保留在测试侧作参考实现
  （见 `docs/contract-register.md`「参考实现」）。
- **图像读取下沉 Core**：`FloatImageConverter`（`CoreGraphics` + `Accelerate`/vImage）接替 App 层的
  「CGContext + 标量循环」转换；App 自测页只留一层 `UIImage` 包装。分层边界不变：Core 仍只依赖
  Foundation / CoreGraphics / Accelerate。

## 批 8：前段管线（检测 → 透视矫正 → 裁切 → 摆正）

真机实测说明：UVDoc 是「文档已占满帧、只差弯曲」的模型；真实场景照（名片只占画面一小块）直接
去畸变会跑偏。故本批补上**前段**：文档检测 → 透视矫正 + 裁切 → 再交给去畸变。

- **Core：检测契约 + 矫正几何**。新增 `Pipeline/ImageDocumentDetection.swift`（`DocumentDetection`
  四角 + 置信度、`ImageDocumentDetecting` 像素型契约）与 `Geometry/DocumentRectifier.swift`
  （四角 → 单应 → 采样网格 + 目标尺寸，`RectificationPlan`；`rectify` 走 `GridResampler` 这
  **唯一**采样入口，不另写重采样实现）。`DocumentQuad` 补 `area` / `isConvex` / `isWithinUnitSquare`
  / `denormalized(in:)` / `clampedToUnitSquare()`。
- **坐标约定（写死）**：四条契约统一为「归一化坐标 ∈ [0,1]，原点在图像左上角、y 轴向下，顺序
  TL → TR → BR → BL」；采样网格仍按 `grid_sample(align_corners=True)` 约定（-1 → 像素 0，
  +1 → 像素 N-1）。归一化 ↔ 像素用 `align_corners` 口径（与真实图像最大偏差 <0.5 像素）。
- **DDScannerVision：真实现检测 + 成像**。`VisionDocumentDetector` 优先
  `VNDetectDocumentSegmentationRequest`（iOS 15+ / macOS 12+，availability 守卫），失败回退
  `VNDetectRectanglesRequest`，两者都不中 → `ScannerError.documentNotFound`；出口把 Vision 的
  「左下原点」翻到左上原点并钳制到单位正方形。`CoreImagePerspectiveCorrector` 增
  `correctedImage(from:quad:scale:)`（平台成像：CGImage ↔ Float32 平面图；像素重采样仍走 Core）。
- **App 自测页分阶段**：原图 / 检测框叠加 / 裁切+透视矫正后 / 去畸变后，每阶段单独计时。
  **检测不到文档 → 回退整帧直接去畸变**，页面明确写「未检测到文档（已回退）」，不崩不空白。
- **线程纪律（P0）**：整条自测管线**不在主线程**跑（视图 `Task.detached` + `@MainActor` 回填）；
  重跑 / 换图 / 离页会 `cancel()` 上一个任务，取消后不回填过期结果；界面按阶段显示进度
  （载入 → 检测 → 矫正 → 预处理 → 推理 n/N → 重采样）。取消与进度契约收在 Core 的
  `StagedLoop`（逐轮检查取消 + 回报进度，本机可测）。大图守卫：源平面像素数必须
  ≤ `GridResampler.maximumSourcePixelCount`（2^24），否则明确报错。
- **仍未接管线**：`ScanPipeline` 的 `DocumentDetecting`（帧几何入口）仍不含像素，相机/拍摄/
  四角微调属后续批次；本批的像素前段由自测页直接消费。

## 批 10：透视矫正的分解计时与提速

真机 Debug 自测页报「透视矫正 + 裁切」**7107 ms**（输出 2689×3007）。本批先**分解计时**（同机同输入、
Debug + Release 各一份），再按实测数据提速。

- **分解（本机 xmini, 3024×4032 → 2689×3007）**：Debug (a) 38.6 / (b) 975.6 / (c) 1414.1 / (d) 2351.7 ms，
  合计 4762 ms；Release (a) 13.5 / (b) 11.0 / (c) 56.4 / (d) 24.0 ms，合计 95.2 ms。
  ⇒ **7107 ms 是 Debug（-Onone）现象**：同一段代码 Release 已 ≈95 ms（≤ 200 ms 目标 2× 富余）；
  大象跑的是 Debug ⌘R，所以体感慢，但不能把它当发布性能。
- **向量化两处**（保持「重采样只有 `GridResampler` 一个入口」不变，产品路径不增第二份实现）：
  - `DocumentRectifier.samplingGrid`（(b)）：逐像素双重循环 → vDSP 行向量化（Double 精度）。
    分母保护从逐行归约改为**四角一次性判定**（`den` 在 [0,1]² 上仿射，四角同号即整幅不跨零）——
    逐行 `vDSP_minmgvD` 归约是首版的性能回退源（Release 18.8 ms > 标量 13.0 ms，改后 11.1 ms）。
  - `FloatImageConverter.makeCGImage`（(d)）：逐像素标量循环 → 逐通道 vDSP 缩放/钳制 + 带菱形步长的
    取整写回（`Float → Double → +0.5 → 截断`），数值语义与旧实现**逐字节一致**。
- **效果（同口径）**：Debug (b) 975.6 → 24.3 ms、(d) 2351.7 → 55.1 ms，合计 4762 → 1521 ms；
  Release (b) 11.0 → 11.1 ms、(d) 24.0 → 22.0 ms，合计 95.2 → 94.0 ms（不回退；Division 吞吐是 Release 下界）。
- **Debug 仍是 1521 ms，瓶颈已变成 (c) 重采样 1412 ms**（`AcceleratedGridResampler` 在 -Onone 下调 vDSP
  的逐行 Swift 侧开销）——该项**不在本批范围**（且不得新增第二份重采样实现），留待后续批次。
- **契约**：两个参考实现（`ScalarSamplingGridReference` / `LegacyFloatImageReference.pixelBuffer`）+ 两份等价性
  测试（`SamplingGridEquivalenceTests` ≤ 1e-6 / `PixelRenderingEquivalenceTests` 逐字节），登记见
  `docs/contract-register.md`；Core 用例数下限 80 → **95**。
- **P1（边界语义实测）**：上游 `utils.bilinear_unwarping` 调 `F.grid_sample` 未传 `padding_mode` ⇒ PyTorch
  默认 `zeros`（越界趋向黑边）；我们越界 **clamp 到边缘**（≡ PyTorch `border`）。实测（torch 2.14.0，
  3×3 图 + 网格 x = [-1.5, 0, 1.5]）：zeros → [1.5, 4.0, 2.5]，border → [3.0, 4.0, 5.0]。
  **本批不改语义**（方向类决策，交 maintainer）；差异钉在 `GridPaddingSemanticsTests`，登记见 contract-register。

## 批 20：去畸变「内容不丢」（不再裁掉四边）

真机实测反馈「**最下面给裁切掉了一部分（是 UVDoc 干的）**」。批 19 只读 spike 定位并验证修法：

- **根因**：UVDoc 输出的网格坐标范围**只覆盖源图一个子矩形**（各边内缩 1.3%–6.0%）；
  而重采样画布仍按「输出尺寸 = 源图尺寸」铺满 ⇒ 源图四条边条从未被采样。
  实测产品路径（`-03-rectified` → UVDoc）上 **9.4%–14.1% 的源图像素从未被采样**
  （paper-1344 左 6.01% / 下 4.83%；notice-1343 合计 14.1%）。「画布 = 源图尺寸」只是放大器。
- **Core 新增修复（FIX-A）**：`Geometry/SourceCoveringGrid.swift` 的
  `NormalizedSampleGrid.extendedToCoverSource()` —— 沿边界斜率**线性外推**网格直到覆盖整幅源图，
  再**按轴仿射归一化**到恰好 `[-1, 1]²`，照旧走 `GridResampler.resample`。
  **不新增第二份重采样实现**（本文件只做网格坐标数学，不采样像素）。
  - **no-op 安全**：网格已覆盖 `[-1, 1]²`（恒等网格、铺满的网格）→ 原样返回；
    非有限值 / 零跨度（单点、共线）→ 原样返回。
  - **效果**：四边丢失量 → **0.0 px**；只去掉原有 1.05–1.11× 的内缩放大（采样比例还原 ~1:1），
    内边形变形状不变、锐度不降反升、耗时几乎不增。
- **接线**：去畸变路径——APP 自测页 `App/Dev/DewarpSelfTestRunner.swift` 的全分辨率重采样前先
  `grid.extendedToCoverSource()`。**生产路径待接**：`ScanPipeline.makeGrid` → `PageDewarping.samplingGrid`
  产出的是 `SampleGrid`（归一化 `[0,1]`，**尚无像素消费者**），等该网格落像素那一处再接同一入口。
- **不误伤透视矫正**：`DocumentRectifier` 的网格**本就该按四边形铺满**，本批**未改动**、也不调用本入口。
- **契约**：`SourceCoveringGridTests`（内容不丢正向 + 修复前 = 0 的反向锚 + 内部几何逐点残差 = 0 +
  no-op + 退化 + 外推几何钉死）；Core 用例数下限 95 → **104**。

## 批 25：纸张增强（去折痕 / 提白 / 换纸色）

大象需求：「把亮度高于某个数值的像素都变成白纸的颜色，就可以把纸面上的折痕消除。」拍板做进 App、
几种纸色都放进去（默认白、用户在设置里选）、默认白度 **255 档**、PS 死白 **310 档**留用户拉；
本批只做 **Core 引擎 + 参数 + 自测页接入**（App 尚无设置页 / 扫描 UI）。

- **Core 新增**：`Imaging/PaperEnhancer.swift`（纯函数式增强器 + 选项 + 纸色预设 + sRGB ↔ 线性查表）
  与 `Imaging/LinearMorphology.swift`（线性域大核椭圆形态学闭）。分层不变：
  仍只依赖 Foundation / CoreGraphics / Accelerate（`check-forbidden-imports.sh` 守着）。
  - 选项：`whiteness`（纸面亮度目标，编码域 0–255，默认 255、上限 310，超出钳制）、
    `paperColor`（默认白；预设 白 / 米白 / 暖黄）；`nil` = 关闭 = **逐字节 no-op**。
  - 算法 = 唯一实测通过的「B」：线性域亮度 → 大核形态学闭估底色（核宽 = 图宽 3.78%，自适应）
    → 92 分位抹平阴影 → **亮度单增益**（不逐通道）→ 乘性纸色 → 回编码域。
- **接线（本批）**：`App/Dev/DewarpSelfTestRunner.swift` / `DewarpSelfTestView.swift` —— 真机上可切
  关闭 / 255 / 310 × 白 / 米白 / 暖黄，并列预览 + 全分辨率当前档。
- **生产路径待接**：`ScanPipeline` 目前只产 `SampleGrid`（**尚无像素消费者**，见批 20 同款说明）；
  位置定为**去畸变之后、导出之前**：等扫描 UI 让网格落像素那一处，把 `PaperEnhancer.enhance` 接上去，
  并把选项（白度 / 纸色）挂到届时新增的设置页。**默认 `nil` 时行为完全不变**。
- **与参考实现逐像素对齐**：真图 10.26 MP，`mean|Δ|` = 1.4e-5 / 255（255 档）、1.1e-5 / 255（310 档），
  `p99` = 0.00/255，`max|Δ|` = 1，>2 像素 = 0。
- **契约**：`PaperEnhancerTests`（12 条）+ 登记见 `docs/contract-register.md`；Core 用例下限 104 → **116**。
