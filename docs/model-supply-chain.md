# 模型供应链（去畸变后端）

## 目标

用 **UVDoc**（Core ML）处理书页弯曲等**非线性**畸变；线性透视畸变由 Core Image 负责。

## 转换链（**定案：原版 PyTorch → torchscript trace → Core ML**）

```
UVDoc 原版权重(PyTorch, MIT)  →  torch.jit.trace + freeze  →  coremltools 9.0
                                                               │
                                                               └─ mlprogram + FLOAT16 + iOS17
```

原计划的 `Paddle → ONNX → Core ML` 路径**未采用**：原版仓库（`tanguymagne/UVDoc`，MIT）自带 checkpoint，
一步 trace 即成，许可干净且少一层格式转换。实测证据见 Spike 001 结论（`corpus` 归档路径）。

- 转换脚本与产物**必须成对入库**（可复现）：改脚本必须重出产物，出产物必须带脚本与版本记录。
  → `Tools/ModelConvert/`（脚本 + 钉版本 `requirements.txt` + 说明）。
- **量化时机**：直接用 coremltools 的 `compute_precision=FLOAT16` 出 FP16 产物（实测 ANE 2.28 ms / 16 MB）。
  继续做 INT8 权重线性量化**实测更慢**（2.76 ms，8.1 MB），故不采用。
- **关键决定：重采样不进模型**。网络只出采样网格；`interpolate` + `grid_sample` 由 Swift 侧用
  **Float32** 实现（`Sources/DDScannerCore/.../Geometry/GridResampler.swift`）。若把重采样放进模型，
  FP16 网格坐标量化会让像素误差飙到 ~4.96（真实文档 ≤0.5%）——数据见 `Tools/ModelConvert/README.md`。

## 产物登记（表格随产物更新）

| 产物 | 来源 | 许可 | 转换脚本 | 状态 |
|---|---|---|---|---|
| `Models/UVDocGrid_fp16.mlpackage`（15 MB，FP16 mlprogram，固定 `1×3×712×488`，只出双网格） | 原版 `tanguymagne/UVDoc`（MIT），权重 sha256 `7e90861b…bda23` | **MIT** | `Tools/ModelConvert/convert_uvdoc.py` | **已入库** |

> 权重**原件**不在本仓分发；产物由脚本复现（取原件 → 核 sha256 → 转换 → `--verify`），见 `Models/README.md`。

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
