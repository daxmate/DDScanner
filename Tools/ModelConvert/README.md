# Tools/ModelConvert —— UVDoc → Core ML 网格模型（生产转换脚本）

本目录是 `Models/UVDocGrid_fp16.mlpackage` 的**唯一生成来源**。产物与脚本必须成对改动
（见 `docs/model-supply-chain.md`）：改脚本 → 重出产物；换产物 → 同一提交里更新脚本/依赖记录。

## 产物契约（改这里前先读）

| 项 | 值 |
|---|---|
| 输入 | `image`，`1×3×712×488`，Float32，**RGB 归一化到 [0,1]** |
| 输出 | `point_positions2D` `1×2×45×31`（采样网格，归一化坐标）、`point_positions3D` `1×3×45×31`（App 未用，保留上游保真） |
| 网格尺寸 | `45×31` = 编码器 16 倍下采样后的尺寸（`712/16`、`488/16` 向上取整） |
| 格式 | `mlprogram` + FLOAT16，`minimum_deployment_target = iOS17` |
| 体积 | 约 16 MB（`Models/` 纯 git 入库，不用 LFS） |
| 网格约定 | 与 PyTorch `grid_sample(..., align_corners=True)` 一致：`-1 → 像素 0`，`+1 → 像素 (N-1)` |

## 为什么重采样不放进模型（关键决定）

网络**只出网格**，`interpolate` + `grid_sample` 留在 Swift 侧用 **Float32** 做。理由是实测数据，
不是偏好：

- 把重采样放进模型（Core ML 的 `resample` 算子）时，FP16 下**误差由网格坐标的 FP16 量化主导**，
  不是网络本身：随机噪声图上 `max_abs = 4.963`；FP16 网格步长约 `2/487 ≈ 0.0041`/像素，
  而 1.0 附近的 FP16 ulp ≈ `0.00098` ≈ **0.24 像素**，高频内容上会混入 ~24% 的邻像素。
- 真实（平滑）文档像素上该误差 ≤0.5%，但identity 网格 + 噪声图就能复现 ~0.56 的误差 —— 说明
  瓶颈是精度而不是语义。
- 网格本身 FP16 误差只有 `1e-2` 量级（≈网格 std 的 0.08%…2.2%），对最终像素的影响远小于
  直接在 FP16 里做重采样。

结论：**模型只出网格 + Swift 侧 Float32 重采样** = 精度更好、模型更简单、ANE 友好。
完整实测见 `docs/model-supply-chain.md` 引用的 Spike 001 结论；Swift 侧实现见
`Sources/DDScannerCore/.../Geometry/GridResampler.swift`。

## 怎么跑

需要 Python **3.13**（本机 `python3` 是 3.14，过新）。

```bash
cd <repo>
python3.13 -m venv /tmp/uvdoc-convert-venv
/tmp/uvdoc-convert-venv/bin/pip install -r Tools/ModelConvert/requirements.txt

# 上游网络定义（MIT）+ 权重：本仓库**不**分发权重，需自行取原件
git clone https://github.com/tanguymagne/UVDoc /tmp/UVDoc

/tmp/uvdoc-convert-venv/bin/python Tools/ModelConvert/convert_uvdoc.py \
  --uvdoc-source /tmp/UVDoc \
  --weights /tmp/UVDoc/model/best_model.pkl \
  --output Models/UVDocGrid_fp16.mlpackage \
  --verify
```

`--verify` 会用固定输入把转换后的模型与 trace 出的 PyTorch 参考网格对比，超容差即 **abort**（不让
不可信产物落盘）。实测（本机 M5 Pro / macOS 27 / coremltools 9.0 / torch 2.14.0）：

```
▶ 来源取证
  weights  sha256 = 7e90861b8a516eb4bc51f84bd889cb77275743d2d1d3ca8091951ec9f2b7da23
  model.py sha256 = 320f460edc54cf830dfdd9788dfbc1b96a836429b64ed6078a30582be6f59e42
✅ point_positions2D: max_abs_diff=0.000499547 (容差 0.03)
✅ point_positions3D: max_abs_diff=0.00046283  (容差 0.03)
```

### 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `--uvdoc-source` | 必填 | UVDoc 仓库检出路径（只从中 `import model`，**不 vendored 副本**，避免架构漂移） |
| `--weights` | 必填 | 上游 `model/best_model.pkl` 路径（不在本仓分发） |
| `--output` | 必填 | 写出的 `.mlpackage` 路径 |
| `--height` / `--width` | `712` / `488` | 固定输入尺寸（改它就得同步改 Swift 侧预处理与网格尺寸） |
| `--precision` | `float16` | `float16` / `float32`（FP16 = 16MB + ANE 最快；FP32 = 32MB，仅在需要极限精度时用） |
| `--deployment-target` | `iOS17` | `iOS17` / `iOS18` / `iOS26` |
| `--verify` | 关 | 兜底数值校验 |

### 已知告警（不阻断）

- `Torch version 2.14.0 has not been tested with coremltools` —— coremltools 9.0 官方测试到 2.7；
  该组合是 Spike 001 与本次生产转换的实测可用组合，产物数值已用 `--verify` 核过。
- `Support for converting Torch Script Models is experimental` / `torch.jit.trace is deprecated`
  —— 上游路径仍是 torchscript trace；后续若迁 `torch.export`/ExecuTorch 需重跑一遍实测。

## 许可

上游 `tanguymagne/UVDoc` 为 **MIT**（代码与权重同仓）。分发时保留版权与许可全文，
见仓库根 `NOTICE.md` 与本目录产物登记 `Models/README.md`。
