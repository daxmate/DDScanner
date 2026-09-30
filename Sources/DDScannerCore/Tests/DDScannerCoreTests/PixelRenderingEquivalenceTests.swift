// FloatImage → 像素缓冲等价性契约：向量化实现（产品路径）vs 旧逐像素标量实现（测试侧参考实现）。
//
// 这份契约比一般的「数值容差」更强：**逐字节完全一致**（`[UInt8]` 全等）。理由是这条路径的
// 唯一「浮动」环节是取整——`value * 255` 与钳制都在 Float 域（与旧实现同精度同顺序），取整走
// Double（`+ 0.5` 在 Double 内精确）+ 截断，对非负值等价于 `.rounded()` 的「半值远离零」默认语义，
// 因此没有容差窗口。用例覆盖：
//   ① 0→255 全阶梯（量化基准）；
//   ② 取整边界密集扫（每个半整数点及其 ±1 ULP 邻域）——取整语义写错会在这里立刻暴露；
//   ③ 三通道图案（通道错位 / 混色会暴露）；
//   ④ 值域外与非有限值（NaN / ±∞）。
import CoreGraphics
import Foundation
import Testing
@testable import DDScannerCore

@Suite("FloatImage → 像素缓冲等价性（向量化 vs 旧标量实现）")
struct PixelRenderingEquivalenceTests {
    /// 首个不同的字节下标；`nil` = 完全一致。
    private static func firstDifference(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int? {
        precondition(lhs.count == rhs.count, "两个缓冲长度必须一致才能比对")
        for index in 0 ..< lhs.count where lhs[index] != rhs[index] {
            return index
        }
        return nil
    }

    /// 逐字节比对产品路径（`rgbPixelBuffer`）与旧实现；不一致时给出下标与两侧取值。
    private static func expectIdentical(_ image: FloatImage) {
        let product = FloatImageConverter.rgbPixelBuffer(from: image)
        let reference = LegacyFloatImageReference.pixelBuffer(from: image)
        let productBuffer = try! #require(product)
        let referenceBuffer = try! #require(reference)
        if let index = firstDifference(productBuffer, referenceBuffer) {
            Issue.record(
                "向量化实现与旧实现在第 \(index) 字节不同：产品=\(productBuffer[index])，参考=\(referenceBuffer[index])"
            )
        }
    }

    /// 由行优先二维数组构造单通道图。
    private static func grayscale(_ values: [Float], width: Int, height: Int) -> FloatImage {
        FloatImage(width: width, height: height, channels: 1, values: values)
    }

    // MARK: - 契约用例

    @Test("0→255 全阶梯：逐字节一致，且每个阶梯恰好落在整数值")
    func fullQuantizationRamp() {
        let count = 256
        let values = (0 ..< count).map { Float($0) / 255 }
        let image = Self.grayscale(values, width: count, height: 1)
        Self.expectIdentical(image)
        let buffer = FloatImageConverter.rgbPixelBuffer(from: image)!
        for index in 0 ..< count {
            #expect(buffer[index * 4] == UInt8(index), "第 \(index) 个阶梯应量化为 \(index)")
        }
    }

    @Test("取整边界密集扫（半整数点 ±1 ULP）：逐字节一致")
    func roundingBoundarySweep() {
        // 每个半整数点 (i + 0.5) / 255 及其前后各 1 ULP —— 取整方向写错会在这些点上分叉。
        var values = [Float]()
        for index in 0 ..< 255 {
            let midpoint = (Float(index) + 0.5) / 255
            values.append(midpoint.nextDown)
            values.append(midpoint)
            values.append(midpoint.nextUp)
        }
        let image = Self.grayscale(values, width: values.count, height: 1)
        Self.expectIdentical(image)
    }

    @Test("三通道图案（R/G/B 各不同）：逐字节一致（通道错位会暴露）")
    func threeChannelPattern() {
        let width = 29
        let height = 17
        let plane = width * height
        var values = [Float](repeating: 0, count: plane * 3)
        for index in 0 ..< plane {
            values[index] = Float(index % width) / Float(width - 1)
            values[plane + index] = Float(index / width) / Float(height - 1)
            values[2 * plane + index] = ((index / 3) % 2 == 0) ? 0.25 : 0.75
        }
        Self.expectIdentical(FloatImage(width: width, height: height, channels: 3, values: values))
    }

    @Test("值域外与非有限值（NaN / ±∞ / >1 / <0）：与旧实现逐字节一致")
    func outOfRangeAndNonFinite() {
        let values: [Float] = [.nan, .infinity, -.infinity, 2.5, -1.5, 0, 1, 0.5, 1e-30, 255, -0.0001]
        let image = Self.grayscale(values, width: values.count, height: 1)
        Self.expectIdentical(image)
    }

    @Test("双通道图：未使用的第三通道与 X 字节保持 255（与旧实现同）")
    func twoChannelImage() {
        let width = 11
        let height = 7
        let plane = width * height
        var values = [Float](repeating: 0, count: plane * 2)
        for index in 0 ..< plane {
            values[index] = Float(index) / Float(plane - 1)
            values[plane + index] = 0.125
        }
        let image = FloatImage(width: width, height: height, channels: 2, values: values)
        Self.expectIdentical(image)
        let buffer = FloatImageConverter.rgbPixelBuffer(from: image)!
        for index in 0 ..< plane {
            #expect(buffer[index * 4 + 2] == 255, "未使用的第三通道应为 255")
            #expect(buffer[index * 4 + 3] == 255, "X 字节应为 255")
        }
    }
}
