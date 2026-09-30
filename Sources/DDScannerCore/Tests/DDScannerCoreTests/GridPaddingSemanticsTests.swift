// 越界填充语义的特征测试（批 10 的 P1：承批 8 遗留问题）。
//
// 背景：上游 UVDoc `utils.bilinear_unwarping`（`/tmp/ddscanner-spike/src/utils.py`）把粗网格双线性插值到
// 目标分辨率后调 `F.grid_sample(..., align_corners=True)`，**未传 `padding_mode`** ⇒ PyTorch 默认
// `'zeros'`：坐标落在图像外时按 0 参与加权（越界部分趋向黑边）。我们的 `GridResampler` 越界一律
// **clamp 到边缘像素**（等价于 PyTorch 的 `padding_mode='border'`）。
//
// 本文件把这条**有意的语义分歧**钉住（数值为实测，非推导）：
//   输入 3×3 单通道 `v[y][x] = y·3 + x`，网格 x = [-1.5, 0, 1.5]（y = 0），align_corners=True。
//   实测（torch 2.14.0，命令见下）：
//     PyTorch zeros（= 上游）→ [1.5, 4.0, 2.5]
//     PyTorch border（= 我们）→ [3.0, 4.0, 5.0]
//   复现（把两个结果各自打印出来即可）：
//     /tmp/ddscanner-spike/venv/bin/python - <<'PY'
//     import torch, torch.nn.functional as F
//     img = torch.arange(9, dtype=torch.float32).reshape(1, 1, 3, 3)
//     grid = torch.tensor([[[[-1.5, 0.0], [0.0, 0.0], [1.5, 0.0]]]], dtype=torch.float32)
//     F.grid_sample(img, grid, align_corners=True).flatten().tolist()                          # zeros  → [1.5, 4.0, 2.5]
//     F.grid_sample(img, grid, align_corners=True, padding_mode='border').flatten().tolist()   # border → [3.0, 4.0, 5.0]
//     PY
//
// 为什么不改成 zeros：这是**产品语义取向**问题（zeros 对齐上游参考实现；clamp 不引入黑边），
// 且「真实模型输出的网格是否会越界」尚未实测 → 属方向类决策，交 maintainer；本批只落数据。
import Foundation
import Testing
@testable import DDScannerCore

@Suite("越界填充语义（clamp vs 上游 zeros）")
struct GridPaddingSemanticsTests {
    /// 3×3 单通道图，`v[y][x] = y·3 + x`。
    private static func ramp3x3() -> FloatImage {
        FloatImage(width: 3, height: 3, channels: 1, values: (0 ..< 9).map(Float.init))
    }

    private static func sample(_ xValues: [Float]) -> [Float] {
        let grid = NormalizedSampleGrid(
            columns: xValues.count,
            rows: 1,
            xValues: xValues,
            yValues: [Float](repeating: 0, count: xValues.count)
        )
        let output = GridResampler.resample(
            grid: grid, source: ramp3x3(), targetWidth: xValues.count, targetHeight: 1
        )
        return (0 ..< xValues.count).map { output.value(x: $0, y: 0, channel: 0)! }
    }

    @Test("越界坐标 clamp 到边缘像素（= PyTorch border，非 zeros）")
    func outOfRangeClampsToEdge() {
        let values = Self.sample([-1.5, 0.0, 1.5])
        #expect(abs(values[0] - 3.0) < 1e-6, "x=-1.5 应 clamp 到左边缘像素 3（PyTorch zeros 为 1.5）")
        #expect(abs(values[1] - 4.0) < 1e-6, "x=0 居中像素 4")
        #expect(abs(values[2] - 5.0) < 1e-6, "x=1.5 应 clamp 到右边缘像素 5（PyTorch zeros 为 2.5）")
    }

    @Test("单个越界点：结果等于边缘像素，而不是按越界比例衰减到 0")
    func singleOutOfRangePointKeepsEdgeValue() {
        let values = Self.sample([-1.5])
        #expect(abs(values[0] - 3.0) < 1e-6)
        // 反向：若把实现改成 zeros 语义，这里会变成 1.5 → 必红。
        #expect(abs(values[0] - 1.5) > 1e-3, "本实现**不应**采用上游的 zeros 语义")
    }
}
