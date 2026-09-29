# 模型供应链（去畸变后端）

## 目标

用 **UVDoc**（Core ML）处理书页弯曲等**非线性**畸变；线性透视畸变由 Core Image 负责。

## 转换链（Paddle → ONNX → Core ML）

```
UVDoc 权重(Paddle)  →  ONNX(opset 待定)  →  coremltools  →  UVDoc.mlpackage
                                             │
                                             └─ mlprogram + FLOAT16（利于 ANE）
```

- 转换脚本与产物**必须成对入库**（可复现）：改脚本必须重出产物，出产物必须带脚本与版本记录。
- 量化时机：先转 `.mlpackage`，再用 `coremltools.optimize.coreml` 做权重线性量化（不在导出前量化）。
- 已知难点（动手前先验证，勿凭记忆）：UVDoc 的双头网格输出与 `F.grid_sample` 双线性采样，
  多半需要在 Core ML 图外自行实现重采样。

## 产物登记（表格随产物更新）

| 产物 | 来源 | 许可 | 转换脚本 | 状态 |
|---|---|---|---|---|
| `UVDoc.mlpackage` | `PaddlePaddle/UVDoc`（Apache-2.0）/ 原版 `tanguymagne/UVDoc`（MIT） | Apache-2.0 / MIT | 待补 | **未入库**（批 1 只有协议与占位后端） |

> 许可结论来源：工作区取证产物 `memory/DDScanner/license-facts-2026-09-29.md`
> （代码 Apache-2.0/MIT 已实锤；权重经 HF 镜像 API 确认为 `apache-2.0`、`gated: false`）。
> 分发时必须随附 LICENSE 全文、版权/出处标注，并在修改过源码时声明「已修改」（Apache-2.0 §4）。

## 模型准入规则

- 只允许 **MIT / Apache-2.0 / BSD**；无许可仓库（如 `D2Dewarp`、`DRCCBI`）与自定义许可
  （`DocTr`，许可条款未核清）**一律不得引入**。检查：`scripts/check-dependency-licenses.sh`。
- 权重页许可必须在**引入前**实锤（官方页面或官方 API 原文），不得用搜索摘要当结论。

## 真机基准报告要求（模型入库的前置条件）

每份模型产物必须附一份真机基准报告，至少包含：

1. **机型与芯片**（如 iPhone 15 Pro / A17 Pro），以及 iOS 版本。
2. **耗时**：预处理 / 推理 / 重采样 / 后处理分段计时，并给 P50 / P95。
3. **内存**：峰值常驻增量（相对无模型基线）。
4. **输入尺寸** 与 **输出网格分辨率**。
5. **降级策略实测**：模型不可用时的回落路径（不得静默失败）。
6. 与**上一版模型**的同机对比（耗时/内存/样张 A/B 结论）。
