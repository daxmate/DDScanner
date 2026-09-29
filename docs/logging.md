# 日志规范

## 教训来源（为什么要有这份文档）

QQPlayer 的历史事故：`stdout.log` 一度涨到 **49MB 且无轮转**，随后排查困难、磁盘被吞。
根因不是「日志写多了」，而是**没有统一出口、没有分级过滤、没有轮转上限**。
DDScanner 从第一行代码起就把出口收口。

## 规则

1. **唯一出口**：任何模块都不得直接 `print(` / `NSLog` / 写文件。
   统一走 `Sources/DDScannerCore/Sources/DDScannerCore/Logging/AppLog.swift`。
   → `scripts/check-structural-budget.sh` 会在产品代码里拦截裸 `print(`。
2. **分级**：`debug` / `info` / `warning` / `error`；Release 默认从 `info` 起（`debug` 编译期可关）。
3. **分类**：`app` / `pipeline` / `capture` / `vision` / `dewarp` / `export` / `storage`。
   每条日志必须带分类，便于按子系统过滤。
4. **落地目标可插拔**：`AppLog.addSink(_:)` 追加 sink；默认 stderr（`StandardErrorLogSink`）。
   `os.Logger` 扇出、文件落地由 platforms 层在装配时注入（见 `App/AppCompositionRoot.swift`）。
5. **轮转上限**：任何文件 sink 必须显式配置**单文件上限 + 保留份数**，默认
   单文件 ≤ 5MB、保留 ≤ 3 份；无上限的 sink 不得合入。
6. **不含敏感内容**：文档内容、图像数据、用户路径一律不入日志。
7. **作用域豁免**：`Tests/` 与 `scripts/` 允许 `print(`（测试断言与 CLI 输出），
   但**产品代码（`Sources/`、`App/`）零容忍**。

## 排故用法

时序 / 播放类的疑难问题，第一动作是**在关键决策点加日志看事实**（值 + 时机），
不读代码猜。日志是取证手段，取证结论要写回 `docs/` 或项目档案。
