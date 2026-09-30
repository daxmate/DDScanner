# 契约登记表

> 每份契约测试守什么语义、白名单理由是什么，**必须逐条登记**。新增契约未登记 → 
> `ContractRegisterContractTests.swift` 判红（契约清单不许腐烂）。

## 机制（所有契约共用）

- **纯扫描**：契约只读源码/资源文本做断言，不启动 App、不起模拟器。
- **fail-closed 白名单**：豁免必须有理由列（`path<TAB>reason`）；缺理由 = 解析失败 = 契约红。
- **自证用例（G4）**：每条契约必须带「注入违规 → 必须红」的用例，否则测试信号不可信。
- **无棘轮**：从零起步的项目不冻结存量计数，超限即红。

## 契约清单

| 契约文件 | 守什么语义 | 白名单 / 数据文件 | 自证方式 |
|---|---|---|---|
| `StructuralBudgetContractTests.swift` | 单 Swift 文件 ≤ 600 行；产品代码（`Sources/`、`App/`）禁裸 `print(` | `Tests/Fixtures/structural-budget-whitelist.tsv`（path+reason，当前为空表） | 注入 601 行文件 / 注入裸 print / 白名单缺理由 |
| `EnvironmentInjectionContractTests.swift` | 构造 `ScanEnvironment` 的文件唯一且为 `App/AppCompositionRoot.swift`；消费端必须登记 | `Tests/Fixtures/environment-consumers.tsv`（消费者→理由） | 注入第二个装配点 / 注入未登记消费端 / 登记表缺理由 |
| `LocalizationKeySetContractTests.swift` | 多语 `Localizable.strings` key 集合完全一致；代码引用的 key 必须存在 | `Resources/{zh-Hans,en}.lproj/Localizable.strings` | 注入缺键 / 注入坏行（fail-closed） |
| `ContractRegisterContractTests.swift` | 本表必须登记 `Tests/ContractTests` 下每一份 `*ContractTests.swift` | 本文件 | 注入未登记的契约文件名 |

## 白名单理由（登记口径）

- 白名单只用于**无法立刻修掉的既有豁免**，必须写清「为什么现在不能修」+ 指向对应 issue。
- 白名单为空是合法状态：本仓从零起步，**豁免应为 0**。
- 新增豁免必须与它指向的修复计划同批提交，不允许「先豁免、后补计划」。

## 参考实现（test-only，**不算产品路径**）

批 7 / 批 10 把几处热点向量化后，旧实现**没有删**，而是原样搬进测试 target 作参照物。
**产品路径只有一份实现**；参考实现不得被产品代码引用，也不得再改写法（一旦被"顺手优化"，它就不再是参照物）。

| 参考实现（测试 target） | 产品实现（唯一） | 守它的测试 | 用途 |
|---|---|---|---|
| `Sources/DDScannerCore/Tests/DDScannerCoreTests/ReferenceImplementations/ScalarGridResamplerReference.swift`（标量网格重采样，`8f0dfd5` 的 `GridResampler.resample` 原样拷贝） | `Sources/DDScannerCore/Sources/DDScannerCore/Geometry/AcceleratedGridResampler.swift`（Accelerate / vDSP） | `GridResampleEquivalenceTests`（max abs diff ≤ 1e-3；反向验证：阈值改 1e-9 必红） | 等价性基准 + 性能基准的「改动前」同口径数字 |
| `.../ReferenceImplementations/ScalarSamplingGridReference.swift`（标量采样网格生成，`d96d0a2` 的 `DocumentRectifier.samplingGrid` 原样拷贝） | `Sources/DDScannerCore/Sources/DDScannerCore/Geometry/DocumentRectifier.swift` 的 `samplingGrid(homography:targetWidth:targetHeight:)`（Accelerate / vDSP，Double 精度） | `SamplingGridEquivalenceTests`（逐点 ≤ 1e-6；反向验证：把 `h1 → h2` 等符号改错 → 5/7 用例必红） | 同上 |
| `.../ReferenceImplementations/LegacyFloatImageReference.swift`（① `CGContext` `.high` + 标量循环；② `makeCGImage` 逐像素写字节循环） | `Sources/DDScannerCore/Sources/DDScannerCore/Imaging/FloatImageConverter.swift`（vImage / vDSP） | `FloatImageConverterTests`（纯色不变量 / 同尺寸逐点 / 缩放接近度）、`PixelRenderingEquivalenceTests`（`rgbPixelBuffer` **逐字节一致**；反向验证：去掉 Double 域 `+0.5` → 4/5 用例必红） | 同上 |

## 运行方式

```bash
swift test --package-path Sources/DDScannerCore       # Core 单测（含等价性契约）
swift test --package-path Tests                       # 全部契约（macOS 本地，无模拟器）
swift test --package-path Tests --filter StructuralBudget   # 单条
```

性能基准（默认不开、不进 CI，**必须 release** 才与真机口径一致）：

```bash
DDSCANNER_BENCH=1 swift test -c release --package-path Sources/DDScannerCore --filter PerformanceBenchmarkTests
# 批 10：「透视矫正 + 裁切」四段分解计时（(a) 整帧转 Float32 / (b) 采样网格生成 / (c) 重采样 / (d) 转 CGImage）
DDSCANNER_BENCH=1 swift test -c release --package-path Sources/DDScannerCore --filter RectificationDecomposition
```

CI 同一条命令跑（`ci.yml` job `core-tests`），保证本地与 CI 同源。

### 纸张增强（去折痕 / 提白 / 换纸色）（批 25）

大象需求原话：「将亮度高于某个数值的像素都变成白纸的颜色，这样就可以把纸面上面的折痕给消除了。」
拍板：**做进 App**；**几种纸色都放进去、默认白色、用户在设置里选**；**默认白度 = 255 档**
（保守档），**PS 那种死白 = 310 档**留给用户拉；本批范围 = **Core 引擎 + 参数 + 自测页接入**。

- **口径（唯一实测通过的「B」方案）**：线性域取亮度（`0.299R+0.587G+0.114B`，编码域加权后转线性）
  → **大核形态学闭**（椭圆核，核宽 = 图宽 × 3.78%，2669px → 101）估计纸面底色 `bg`
  → 纸面参考 = `bg` 的 92 分位（锚点：源图纸面亮度中位数编码 ≈190 ↔ 255 档）
  → **亮度单增益**（**不逐通道**；批 23 已证逐通道会黄偏 ΔE 17.9）`out = clip(img · gain)`
  → 乘性纸色 → 回编码域。
- **默认安全**：`PaperEnhancer.enhance(_:options:)` 传 `nil`（或非 3 通道）→ **逐字节 no-op**，
  不重采样、不改数值。白度超出 `[0, 310]` 钳制。
- **实测口径（批 25 报告）**：`whiteness=255` → 折痕亮暗两侧一起抹平（`foldGap` 26.74 → **0.00**）、
  浅笔迹保留（`lightP` 18.0 → 30.7）、文字对比度**升**（`txtC` 94.7 → 202.6）；
  `310` → `lightP` **0.00**（浅灰纹理断崖消失，归因「牺牲纸感、不牺牲内容」）；乘性着色无新增彩边。
- **Swift 输出 vs Python 参考实现逐像素对齐**（真图 `IMG_1345`，10.26 MP）：
  `mean|Δ|` = **1.4e-5 / 255**（255 档）、**1.1e-5 / 255**（310 档），`p99` = **0.00/255**，
  `max|Δ|` = 1，**>2 的像素 = 0**。口径差异仅剩「sRGB 走 4096 段查表插值」的 1 LSB 舍入。
- **性能**（xmini，release，2669×3843）：转换 0.14 s；单档全分辨率增强 **≈2.0 s**（形态学是主成本）。
- **接线**：`App/Dev/DewarpSelfTestRunner.swift` + `DewarpSelfTestView.swift` —— 真机可切
  「关闭 / 白度 255 / 白度 310 × 白 / 米白 / 暖黄」，全分辨率出当前档、并列出各档降采样预览。
  **生产路径待接**：`ScanPipeline` 仍只产出 `SampleGrid`（**无像素消费者**），等扫描 UI 落像素那处再接。
- **契约**：`PaperEnhancerTests`（Tests/DDScannerCoreTests）—— 关闭 = 逐字节 no-op / 折痕**亮暗两侧**
  一起抹平（否定纯阈值方案）/ 平坦页背景 std 降 ≥ 一个量级 / 纸色 ΔE ≤ 2 / 浅色内容保留 /
  文字对比度不降 / 退化（全黑·全白·1×1·1×N·非有限值·超大 whiteness）/ 确定性 / 核宽自适应 /
  椭圆核逐行半宽与 cv2 同公式 / 形态学语义。**Core 用例下限 104 → 116**。

### 测试信号守卫（防「0 用例假绿」）

`swift test` 在**一条用例都没跑**时退出码仍是 0 —— `--filter` 匹配 0 条（批 1 教训）、测试 target 被改名、扫不到用例文件都会这样。**只看退出码 = 假绿**。

CI 的三个测试 step（Core / 契约 / Dewarp）都把输出落盘后调 `scripts/check-test-signal.sh <日志> <用例数下限>`：取不到 `Test run with N tests` 行、或实测数量低于下限，一律红。下限取**登记时的实测值**（Core 104 / 契约 17 / Dewarp 6）；包内用例减少即红，用例增长后应把 ci.yml 里的下限同步上调。

### SPM 包与测试 target 零警告（G1 补齐）

`scripts/check-zero-warnings.sh` 原有的 `build` / `build-for-testing` 走 `xcodebuild -scheme DDScanner`，只编 Xcode scheme 里的 App/库 target，**编不到 SPM 测试 target**（`DDScannerCoreTests` / `DDScannerDewarpTests` / `ContractTests`）。批 8 的 `Thread.isMainThread` 告警（Swift 6 起为 error）正是从这条缝漏过 CI 的。

- 新增 action：`scripts/check-zero-warnings.sh packages` —— 对五个 SPM 包（Core / Dewarp / Export / Vision / Tests）× {debug, release} 跑 `swift build --build-tests`，日志 grep `warning:` 即红。
- **fail-closed**：任一包构建失败、或日志里没有 `Build complete!` 成功标记、或零警告命中，一律 exit 1。
- release 额外传 `-Xswiftc -enable-testing`：`swift build` 在 release 下不给库 target 传该 flag，`@testable import` 会编译失败（`swift test` 自带该行为）；只影响可测性，不改变诊断口径。
- CI 落点：`ci.yml` job `core-tests` 的**首个 step** —— debug 构建产物与后续三个 `swift test` step 共用 `.build`，净增 ≈ release 一轮。
- 自证（双向）：把 `Sources/DDScannerCore/Tests/DDScannerCoreTests/BackgroundExecutionTests.swift` 还原为修复前（两处 `!Thread.isMainThread`）→ `packages` 必须红（debug 与 release 都命中）；修复后必须绿。

### 去畸变「覆盖整幅源图」（批 20，**行为变更：不再裁掉边条**）

上游 UVDoc 输出的网格坐标范围**只覆盖源图一个子矩形**（各边内缩 1.3%–6.0%），而重采样画布按
「输出尺寸 = 源图尺寸」铺满 ⇒ 源图四条边条从未被采样（实测产品路径上 9.4%–14.1% 的像素丢失）。

- **产品语义变更**：去畸变重采样前先把网格扩展成**覆盖整幅源图 `[-1, 1]²`** ——
  `NormalizedSampleGrid.extendedToCoverSource()`（`Geometry/SourceCoveringGrid.swift`）：
  沿边界斜率线性外推 → 按轴仿射归一化到恰好 `[-1, 1]²`，再照旧走 `GridResampler.resample`。
  结果是**输出不再裁掉四边**、且不再把内缩子矩形放大（采样比例还原为 ~1:1）。
- **不新增第二份重采样实现**：本文件只做网格坐标数学，采样仍只有 `GridResampler` 一个入口。
- **安全边界**：网格**已覆盖 `[-1, 1]²`**（恒等网格、铺满的透视矫正网格）→ **原样返回（no-op）**；
  非有限值 / 零跨度（单点、共线）→ 原样返回。
- **不误伤透视矫正**：`DocumentRectifier.samplingGrid`（网格本就该按四边形铺满）**未被改动**，
  也不调用本入口；本次只接去畸变路径。
- 契约：`SourceCoveringGridTests`（`Tests/DDScannerCoreTests/SourceCoveringGridTests.swift`）——
  内容不丢（正向 + 修复前 = 0 的反向锚）/ 内部几何不变（逐点残差 = 0）/ 外推几何钉死 / no-op / 退化。
- 真机与端到端数字见 `memory/DDScanner/surveys/`（批 20 报告）。

### 越界填充语义（批 10 P1，**有意与上游分歧，已钉死**）

上游 UVDoc `utils.bilinear_unwarping` 调 `F.grid_sample` **未传 `padding_mode`** ⇒ PyTorch 默认 `zeros`；
我们的 `GridResampler` 越界一律 **clamp 到边缘**（≡ PyTorch `border`）。实测（torch 2.14.0，3×3 图 +
网格 x = [-1.5, 0, 1.5]）：zeros → [1.5, 4.0, 2.5]，border → [3.0, 4.0, 5.0]。

- 复现命令与推导写在 `Tests/DDScannerCoreTests/GridPaddingSemanticsTests.swift` 头部。
- **本批不改语义**：zeros ↔ clamp 是产品取向（对齐上游 vs 不引入黑边），且「真实模型输出的网格是否越界」未实测 → 方向类决策，交 maintainer。
- 反向验证：若把实现改成 zeros，该两条用例必红。

### shell 变量展开边界（G10）

`scripts/check-shell-quoting.sh` 静态扫描 `scripts/*.sh` 与 `.github/workflows/*.yml`：变量引用（`$` + 变量名）**紧跟非 ASCII 字节**（全角冒号、全角括号等多字节字符）时，bash 5.x + UTF-8 locale 会把多字节字节并入变量名 → `set -u` 下报 unbound variable；而 macOS 自带旧 bash（3.2.57）不重现 → 本地自验假绿、CI 才红。命中即红（打印 `文件:行: 原文`）；**fail-closed**：待扫目录缺失/不可读、或一个待扫文件都没有，一律判红。修法：花括号定界（`${VAR}`）。

- 注释行不豁免（同类写法被粘贴回代码同样是隐患）。
- CI 落点：`ci.yml` job `gates` 的 step「shell 变量展开边界（G10）」。
- 自证：往任一 `scripts/*.sh` 注入一行引用后紧跟全角字符的 `echo` → 必须红；还原后必须绿。
