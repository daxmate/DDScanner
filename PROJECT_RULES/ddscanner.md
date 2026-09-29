# DDScanner 项目专项细则

> 通用纪律见 `AGENTS.md`；子代理通用守则见工作区 `SUBAGENT_RULES.md`。本文件只写本仓特有细则。

## 1. worktree 与并行

- 动手的活一律在**独立 worktree** 内做；主检出保持干净，禁止直接改。
- **同一个 worktree 同时只允许一个会话写**（换手前先停掉前一个会话）。
- 只读侦察可并行；同仓库的**写任务串行**（一条交付 → 复核 → 合入 → 再下一条）。

## 2. 检出卫生

- 开工先 `git status --porcelain`：有别人的未提交改动 → 停下报告，不要动。
- 生成物（`DDScanner.xcodeproj`）入库；改它必须通过 `project.yml` + `scripts/gen-project.sh`。
- 临时产物一律放 `/tmp/`；构建产物放 `.build/`（已 gitignore）。

## 3. 提交完整性

- 提交前必须过本地门禁：`scripts/check-*.sh` + `swiftformat --lint` + `swiftlint`（或直接装 hooks）。
- **限定 pathspec 的 `git add` 会漏提交**：涉及仓库根配置（`project.yml`、`.github/workflows/`、
  `scripts/`、`.swiftlint.yml`、`.swiftformat`）时显式列全，或 `git add -A`；提交后 `git show --stat` 核对。
- commit message 用 conventional commit（`feat:` / `fix:` / `chore:` / `docs:` / `test:`）。
- 遵守 `AGENTS.md` 红线：**不 push（末经用户同意）、不删文件、不手改生成物**。

## 4. 交付流程

1. 自验：`swift test --package-path Sources/DDScannerCore` + `swift test --package-path Tests` +
   全部 `scripts/check-*.sh` + 编译级 `scripts/xcbuild.sh build`（零警告）。
2. 交付 = 分支/提交 + 完成报告；**review / 合入 / push / 清理只由维护者做**。
3. 子代理完成报告必须含：守则版本号、commit 列表、改动文件清单、验证命令与结果、未做事项与假设。

## 5. 真机取证

- **本地禁起模拟器**；UI / 视觉 / 性能一律真机验收（清单：`docs/device-acceptance-checklist.md`）。
- 拿不到日志 → 让 App **落盘**再取；不要把「容器里看不到文件」当成「App 没在用」。
- 排故第一动作是加日志看事实（统一出口 `AppLog`，见 `docs/logging.md`）。

## 6. 模型与后端

- 模型转换流程、产物登记与真机基准要求：见 `docs/model-supply-chain.md`。
- 依赖/模型许可白名单与黑名单：见 `AGENTS.md` §0 与 `scripts/check-dependency-licenses.sh`。

## 7. 安装本地 hooks

```bash
git config core.hooksPath scripts/git-hooks     # 启用 pre-commit（G1/G2/G7/G8/G9 本地副本）
SKIP_BUILD=1 git commit ...                     # 需要快提交时跳过重型构建（CI 兜底）
```
