// ⚠️ test-only reference —— 标量网格重采样（**产品路径的旧实现原样保留**）。
//
// 只在测试 target 内编译，不进产品路径：产品路径只有 `AcceleratedGridResampler` 一份实现
// （见 docs/contract-register.md「参考实现」）。用途两项：
//   ① 等价性契约：`GridResampleEquivalenceTests` 逐点比对（max abs diff ≤ 1e-3）；
//   ② 性能基准：`PerformanceBenchmarkTests` 里作为「改动前」的同口径参照。
//
// 本文件是 8f0dfd5 上 `GridResampler.resample` 的逐行拷贝（含它依赖的 4 个私有助手），
// 不改语义、不改写法——它一旦被"顺手优化"就不再是参照物了。
import DDScannerCore
import Foundation

enum ScalarGridResamplerReference {
    static func resample(
        grid: NormalizedSampleGrid,
        source: FloatImage,
        targetWidth: Int,
        targetHeight: Int
    ) -> FloatImage {
        let sourceWidth = source.width
        let sourceHeight = source.height
        let planeSize = sourceWidth * sourceHeight
        let targetPlaneSize = targetWidth * targetHeight
        let lastX = Float(sourceWidth - 1)
        let lastY = Float(sourceHeight - 1)
        var values = [Float](repeating: 0, count: targetPlaneSize * source.channels)

        for row in 0 ..< targetHeight {
            let v = unit(row, count: targetHeight)
            for column in 0 ..< targetWidth {
                let normalized = interpolatedPoint(grid: grid, u: unit(column, count: targetWidth), v: v)
                // 归一化 → 像素坐标（align_corners=True），越界 clamp。
                let sourceX = clamped((normalized.x + 1) * 0.5 * lastX, upper: lastX)
                let sourceY = clamped((normalized.y + 1) * 0.5 * lastY, upper: lastY)
                let x0 = Int(sourceX.rounded(.down))
                let y0 = Int(sourceY.rounded(.down))
                let x1 = min(x0 + 1, sourceWidth - 1)
                let y1 = min(y0 + 1, sourceHeight - 1)
                let fractionX = sourceX - Float(x0)
                let fractionY = sourceY - Float(y0)
                for channel in 0 ..< source.channels {
                    let base = channel * planeSize
                    let topLeft = source.values[base + y0 * sourceWidth + x0]
                    let topRight = source.values[base + y0 * sourceWidth + x1]
                    let bottomLeft = source.values[base + y1 * sourceWidth + x0]
                    let bottomRight = source.values[base + y1 * sourceWidth + x1]
                    let top = topLeft + (topRight - topLeft) * fractionX
                    let bottom = bottomLeft + (bottomRight - bottomLeft) * fractionX
                    values[channel * targetPlaneSize + row * targetWidth + column] =
                        top + (bottom - top) * fractionY
                }
            }
        }
        return FloatImage(width: targetWidth, height: targetHeight, channels: source.channels, values: values)
    }

    /// `align_corners=True` 下第 `index` 个采样点在 `[0, 1]` 上的位置；只有一个点时取 0。
    static func unit(_ index: Int, count: Int) -> Float {
        count > 1 ? Float(index) / Float(count - 1) : 0
    }

    /// 网格在 `(u, v) ∈ [0, 1]` 处的双线性插值坐标（`align_corners=True`）。
    static func interpolatedPoint(grid: NormalizedSampleGrid, u: Float, v: Float) -> (x: Float, y: Float) {
        let gridX = clamped(u, upper: 1) * Float(grid.columns - 1)
        let gridY = clamped(v, upper: 1) * Float(grid.rows - 1)
        let column0 = Int(gridX.rounded(.down))
        let row0 = Int(gridY.rounded(.down))
        let column1 = min(column0 + 1, grid.columns - 1)
        let row1 = min(row0 + 1, grid.rows - 1)
        let fractionX = gridX - Float(column0)
        let fractionY = gridY - Float(row0)

        func interpolate(_ values: [Float]) -> Float {
            let topLeft = values[row0 * grid.columns + column0]
            let topRight = values[row0 * grid.columns + column1]
            let bottomLeft = values[row1 * grid.columns + column0]
            let bottomRight = values[row1 * grid.columns + column1]
            let top = topLeft + (topRight - topLeft) * fractionX
            let bottom = bottomLeft + (bottomRight - bottomLeft) * fractionX
            return top + (bottom - top) * fractionY
        }

        return (sanitized(interpolate(grid.xValues)), sanitized(interpolate(grid.yValues)))
    }

    /// 非有限坐标（NaN / ±∞）视为归一化 0（图像中心）：不让坏网格值传播成坏像素。
    static func sanitized(_ value: Float) -> Float {
        value.isFinite ? value : 0
    }

    /// 非有限值视为 0；其余钳制到 `[0, upper]`。
    static func clamped(_ value: Float, upper: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), max(upper, 0))
    }
}
