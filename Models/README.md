# Models —— 模型产物

> **本目录的文件由 `Tools/ModelConvert/` 生成，勿手改。** 改脚本 → 重出产物（同一提交）。

## UVDocGrid_fp16.mlpackage

| 项 | 值 |
|---|---|
| 用途 | 去畸变（非线性弯曲）网格预测：输入文档像素 → 输出采样网格 |
| 来源 | `tanguymagne/UVDoc`（原版 PyTorch 实现，**MIT**）的 `model/best_model.pkl` |
| 权重 sha256 | `7e90861b8a516eb4bc51f84bd889cb77275743d2d1d3ca8091951ec9f2b7da23`（`best_model.pkl`，32,158,393 B；上游 README 亦标注权重随仓库分发） |
| 上游 `model.py` sha256 | `320f460edc54cf830dfdd9788dfbc1b96a836429b64ed6078a30582be6f59e42` |
| 许可 | **MIT** —— 保留版权声明与许可全文（见根 `NOTICE.md`）；论文引用见下 |
| 生成脚本 | `Tools/ModelConvert/convert_uvdoc.py`（依赖钉版本：`Tools/ModelConvert/requirements.txt`） |
| 体积 | ~16 MB（FP16；FP32 为 32 MB） |
| 格式 | `mlprogram`，`FLOAT16`，`minimum_deployment_target = iOS17` |
| 输入 | `image` `1×3×712×488`，Float32，RGB ∈ [0,1] |
| 输出 | `point_positions2D` `1×2×45×31`（**App 只消费这个**）、`point_positions3D` `1×3×45×31` |
| 网格约定 | 归一化坐标，与 PyTorch `grid_sample(align_corners=True)` 一致 |

### 复现命令

```bash
git clone https://github.com/tanguymagne/UVDoc /tmp/UVDoc
# 先核对权重哈希（见上表 sha256），再转换：
python3.13 -m venv /tmp/uvdoc-convert-venv
/tmp/uvdoc-convert-venv/bin/pip install -r Tools/ModelConvert/requirements.txt
/tmp/uvdoc-convert-venv/bin/python Tools/ModelConvert/convert_uvdoc.py \
  --uvdoc-source /tmp/UVDoc \
  --weights /tmp/UVDoc/model/best_model.pkl \
  --output Models/UVDocGrid_fp16.mlpackage \
  --verify
```

### 论文引用

> Verhoeven, F., Magne, T., Sorkine-Hornung, O. *UVDoc: Neural Grid-based Document Unwarping.*
> SIGGRAPH Asia 2023 (Conference Papers). 项目页：https://igl.ethz.ch/projects/uvdoc/

### 上游版权

```
Copyright (c) UVDoc authors (ETH Zurich) — https://github.com/tanguymagne/UVDoc
Released under the MIT License. See NOTICE.md for the retained attribution.
```

### 真机基准

按 `docs/model-supply-chain.md`，本产物入库后需在**真机**补一份基准报告（机型 / 分段耗时
P50+P95 / 峰值内存 / 降级实测）。Mac 上 FP16 ANE 中位 ~2.28 ms 只是指示值，真机以 App 内
「去畸变自测页」为准，步骤见 `docs/device-test-uvdoc.md`。
