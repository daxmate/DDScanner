# AGENTS.md — DDScanner 项目守则

> 本仓 = 开源文档扫描 App（iOS 17+，Apache-2.0，单仓 monorepo，`github.com/daxmate/DDScanner`）。
> 本文件管**本仓的工程纪律**；子代理通用守则见工作区 `SUBAGENT_RULES.md`（红线优先级最高）。

## 0. 红线（违反 = 任务作废）

- **不 push 前未经用户同意**：功能分支只留本地；`main` 的推送只由维护者执行。
- **不删文件**：删除一律先问；用 `git mv` / `trash`，禁止 `git rm` 与直接 `rm`。
- **依赖白名单**：只允许 **MIT / Apache-2.0 / BSD-2-Clause / BSD-3-Clause**；出现其它许可即红。
  黑名单（许可不明或不可再分发，**禁止引入**）：`D2Dewarp`、`DRCCBI`、`DocTr`。
- **本地禁起模拟器**（`xcodebuild test` / `simctl` 一律先请示）；UI 与视觉一律交用户真机验收。
- **不改生成物源头**：`DDScanner.xcodeproj` 由 `project.yml` 生成，禁手改；改法见 `docs/architecture.md`。

## 1. 六维评分尺子（100 分）

| 维度 | 满分 | 说明 |
|---|---|---|
| 正确性与可靠性 | 25 | 真实 bug 是否被修掉且有回归守护 |
| 测试与 CI | 20 | 测试是否因行为改变而变红（信号），CI 是否守恒 |
| 架构一致性 | 15 | 是否守住分层硬边界与唯一装配点 |
| 可维护性 | 15 | 结构预算、日志出口、命名与重复度 |
| 文档与契约 | 15 | 契约登记表、文档↔代码同步、决策留痕 |
| 合规可发布 | 10 | 许可、隐私声明、App Store 可发布性 |

评分只能来自**当回合现场实测**，禁用记忆中的旧数字；报告须给「上次 → 现在 → Δ」。

## 2. 门禁清单（可执行；详见 `docs/contract-register.md`）

| # | 门禁 | 落点 |
|---|---|---|
| G1 | 零编译警告（Xcode scheme + SPM 包/测试 target） | `scripts/check-zero-warnings.sh`（CI 跑 `build`/`build-for-testing`/`packages`；pre-commit 跑 `build`） |
| G2 | 结构硬上限：单文件 ≤ 600 行、产品代码无裸 `print(` | `scripts/check-structural-budget.sh` |
| G3 | 扫描型契约测试（纯扫描 + fail-closed 白名单带理由） | `Tests/ContractTests/*ContractTests.swift` |
| G4 | 测试信号 fail-closed（每条契约必有「注入违规 → 必须红」自证） | 同 G3 |
| G5 | 组合根唯一装配点 | `Tests/ContractTests/EnvironmentInjectionContractTests.swift` |
| G6 | l10n key 集合一致性（多语必须一致 + 消费端 key 必须存在） | `Tests/ContractTests/LocalizationKeySetContractTests.swift` |
| G7 | 依赖许可扫描 | `scripts/check-dependency-licenses.sh` |
| G8 | lint 锁版本 + 装完自校验 | CI step + `.swiftlint.yml` + `.swiftformat` |
| G9 | 统一构建入口（禁裸 `xcodebuild`） | `scripts/xcbuild.sh` + `scripts/check-build-entry.sh` |
| G10 | shell 变量展开边界（变量引用紧跟非 ASCII 字节 → 花括号定界） | `scripts/check-shell-quoting.sh`（CI job `gates`） |

**无棘轮**：本仓从零起步，结构超限与裸 `print` 的存量必须恒为 0，不引入「只能减不能增」的基线计数。

## 3. 子代理纪律

- 动手的活一律派子代理；任务包首行必须写「先读工作区 `SUBAGENT_RULES.md`」。
- 子代理在**独立 worktree** 内干活，禁止直接改主检出；交付前自验（测试 + 编译 + 门禁）。
- 子代理完成报告要核**实际状态**（`git log` / 文件内容），不接受「报告说全绿」。
- 收尾（review / merge / push / 清理）只由维护者做；子代理报告即终点。

## 4. 真机取证纪律

- 相机与文档扫描**强依赖真机**，模拟器无摄像头 → 本地只做**编译级**验证（走 `scripts/xcbuild.sh`）。
- 任何 UI / 视觉 / 性能结论必须来自**真机**，由用户验收；验收项见 `docs/device-acceptance-checklist.md`。
- 排故第一动作是**加日志看事实**（走统一出口 `AppLog`，见 `docs/logging.md`），不读代码猜。

## 5. 文档 ↔ 代码同步

- 契约、门禁、分层规则与代码**同一次提交**内一起改；`docs/contract-register.md` 必须逐条登记每份契约测试。
- 新增契约测试后跑 `swift test --package-path Tests`（登记表契约会因漏登记而红）。
- 决策与取舍写进 `docs/` 或 `PROJECT_RULES/ddscanner.md`，不留在对话里。
