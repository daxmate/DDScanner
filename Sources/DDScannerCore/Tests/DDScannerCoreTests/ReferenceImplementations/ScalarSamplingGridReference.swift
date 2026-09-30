// ⚠️ test-only reference —— 标量采样网格生成（**产品路径的旧实现原样保留**）。
//
// 只在测试 target 内编译，不进产品路径：产品路径只有 `DocumentRectifier.samplingGrid` 一份实现
// （见 docs/contract-register.md「参考实现」）。用途两项：
//   ① 等价性契约：`SamplingGridEquivalenceTests` 逐点比对（≤ 1e-6）；
//   ② 性能基准：`RectificationDecompositionBenchmarkTests` 里作为「改动前」的同口径参照。
//
// 本文件是 d96d0a2 上 `DocumentRectifier.samplingGrid(homography:targetWidth:targetHeight:)`
// 的逐行拷贝，不改语义、不改写法——它一旦被"顺手优化"就不再是参照物了。
import CoreGraphics
import Foundation
@testable import DDScannerCore

enum ScalarSamplingGridReference {
    static func samplingGrid(homography: Homography, targetWidth: Int, targetHeight: Int) -> NormalizedSampleGrid {
        precondition(targetWidth > 0 && targetHeight > 0, "目标尺寸必须为正")
        var xValues = [Float](repeating: 0, count: targetWidth * targetHeight)
        var yValues = [Float](repeating: 0, count: targetWidth * targetHeight)
        for row in 0 ..< targetHeight {
            let v = GridResampler.unit(row, count: targetHeight)
            for column in 0 ..< targetWidth {
                let u = GridResampler.unit(column, count: targetWidth)
                let source = homography.map(CGPoint(x: Double(u), y: Double(v)))
                let index = row * targetWidth + column
                // 归一化 [0,1] → 采样网格 [-1,1]（-1 = 像素 0，+1 = 像素 N-1）。
                xValues[index] = Float(source.x) * 2 - 1
                yValues[index] = Float(source.y) * 2 - 1
            }
        }
        return NormalizedSampleGrid(columns: targetWidth, rows: targetHeight, xValues: xValues, yValues: yValues)
    }
}
