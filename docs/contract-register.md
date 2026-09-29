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

## 运行方式

```bash
swift test --package-path Tests                    # 全部契约（macOS 本地，无模拟器）
swift test --package-path Tests --filter StructuralBudget   # 单条
```

CI 同一条命令跑（`ci.yml` job `core-tests`），保证本地与 CI 同源。

### 测试信号守卫（防「0 用例假绿」）

`swift test` 在**一条用例都没跑**时退出码仍是 0 —— `--filter` 匹配 0 条（批 1 教训）、测试 target 被改名、扫不到用例文件都会这样。**只看退出码 = 假绿**。

CI 的三个测试 step（Core / 契约 / Dewarp）都把输出落盘后调 `scripts/check-test-signal.sh <日志> <用例数下限>`：取不到 `Test run with N tests` 行、或实测数量低于下限，一律红。下限取**登记时的实测值**（Core 35 / 契约 17 / Dewarp 6）；包内用例减少即红，用例增长后应把 ci.yml 里的下限同步上调。
