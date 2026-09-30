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

批 7 把两处热点向量化后，旧实现**没有删**，而是原样搬进测试 target 作参照物。
**产品路径只有一份实现**；参考实现不得被产品代码引用，也不得再改写法（一旦被"顺手优化"，它就不再是参照物）。

| 参考实现（测试 target） | 产品实现（唯一） | 守它的测试 | 用途 |
|---|---|---|---|
| `Sources/DDScannerCore/Tests/DDScannerCoreTests/ReferenceImplementations/ScalarGridResamplerReference.swift`（标量网格重采样，`8f0dfd5` 的 `GridResampler.resample` 原样拷贝） | `Sources/DDScannerCore/Sources/DDScannerCore/Geometry/AcceleratedGridResampler.swift`（Accelerate / vDSP） | `GridResampleEquivalenceTests`（max abs diff ≤ 1e-3；反向验证：阈值改 1e-9 必红） | 等价性基准 + 性能基准的「改动前」同口径数字 |
| `.../ReferenceImplementations/LegacyFloatImageReference.swift`（`CGContext` `.high` + 标量循环） | `Sources/DDScannerCore/Sources/DDScannerCore/Imaging/FloatImageConverter.swift`（vImage） | `FloatImageConverterTests`（纯色不变量 / 同尺寸逐点 / 缩放接近度） | 同上 |

## 运行方式

```bash
swift test --package-path Sources/DDScannerCore       # Core 单测（含等价性契约）
swift test --package-path Tests                       # 全部契约（macOS 本地，无模拟器）
swift test --package-path Tests --filter StructuralBudget   # 单条
```

性能基准（默认不开、不进 CI，**必须 release** 才与真机口径一致）：

```bash
DDSCANNER_BENCH=1 swift test -c release --package-path Sources/DDScannerCore --filter PerformanceBenchmarkTests
```

CI 同一条命令跑（`ci.yml` job `core-tests`），保证本地与 CI 同源。

### 测试信号守卫（防「0 用例假绿」）

`swift test` 在**一条用例都没跑**时退出码仍是 0 —— `--filter` 匹配 0 条（批 1 教训）、测试 target 被改名、扫不到用例文件都会这样。**只看退出码 = 假绿**。

CI 的三个测试 step（Core / 契约 / Dewarp）都把输出落盘后调 `scripts/check-test-signal.sh <日志> <用例数下限>`：取不到 `Test run with N tests` 行、或实测数量低于下限，一律红。下限取**登记时的实测值**（Core 35 / 契约 17 / Dewarp 6）；包内用例减少即红，用例增长后应把 ci.yml 里的下限同步上调。

### shell 变量展开边界（G10）

`scripts/check-shell-quoting.sh` 静态扫描 `scripts/*.sh` 与 `.github/workflows/*.yml`：变量引用（`$` + 变量名）**紧跟非 ASCII 字节**（全角冒号、全角括号等多字节字符）时，bash 5.x + UTF-8 locale 会把多字节字节并入变量名 → `set -u` 下报 unbound variable；而 macOS 自带旧 bash（3.2.57）不重现 → 本地自验假绿、CI 才红。命中即红（打印 `文件:行: 原文`）；**fail-closed**：待扫目录缺失/不可读、或一个待扫文件都没有，一律判红。修法：花括号定界（`${VAR}`）。

- 注释行不豁免（同类写法被粘贴回代码同样是隐患）。
- CI 落点：`ci.yml` job `gates` 的 step「shell 变量展开边界（G10）」。
- 自证：往任一 `scripts/*.sh` 注入一行引用后紧跟全角字符的 `echo` → 必须红；还原后必须绿。
