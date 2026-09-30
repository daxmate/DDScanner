// SamplingGrid 等价性契约：向量化实现（产品路径）vs 标量实现（测试侧参考实现）。
//
// 阈值 1e-6 的依据：两条路径的算式相同（单应的乘/加结合序刻意对齐），差异只来自 vDSP 可能对
// `a·b + c` 使用 FMA → Double 级 ≤ 1 ULP（约 1e-16 相对），转 Float 后 ≤ 1 ULP（约 1e-7 相对），
// 再 `×2 - 1` 仍在 Float 域 → 逐点差异在 1e-7 量级。1e-6 容得下浮点重排，同时远小于「语义写错」
// 的偏差（行列索引互换、u/v 用错、单应系数下标错位都会到 1e-2 以上）。
//
// 反向验证：把向量化实现里的任一下标/符号改错（如 h6 ↔ h7、`xOffset` 用 h5）→ 本套用例必红。
import CoreGraphics
import Foundation
import Testing
@testable import DDScannerCore

@Suite("SamplingGrid 等价性（向量化 vs 标量参考实现）")
struct SamplingGridEquivalenceTests {
    /// 等价阈值；反向验证时临时改成 1e-9 → 必须红（证明本契约真的在两个实现之间比）。
    private static let tolerance: Float = 1e-6

    private static func maxAbsoluteDifference(_ lhs: NormalizedSampleGrid, _ rhs: NormalizedSampleGrid) -> Float {
        precondition(
            lhs.columns == rhs.columns && lhs.rows == rhs.rows,
            "两个网格行列数必须一致才能比对"
        )
        var maximum: Float = 0
        for index in 0 ..< lhs.xValues.count {
            maximum = max(maximum, abs(lhs.xValues[index] - rhs.xValues[index]))
            maximum = max(maximum, abs(lhs.yValues[index] - rhs.yValues[index]))
        }
        return maximum
    }

    @discardableResult
    private static func expectEquivalent(homography: Homography, width: Int, height: Int) -> Float {
        let product = DocumentRectifier.samplingGrid(
            homography: homography, targetWidth: width, targetHeight: height
        )
        let reference = ScalarSamplingGridReference.samplingGrid(
            homography: homography, targetWidth: width, targetHeight: height
        )
        let difference = maxAbsoluteDifference(product, reference)
        #expect(
            difference <= tolerance,
            "向量化实现与标量参考实现最大绝对差 \(difference) > 阈值 \(tolerance)"
        )
        return difference
    }

    /// 由四角解出「单位正方形 → 四角」的单应（与 `DocumentRectifier.plan` 同方向）。
    private static func homography(for quad: DocumentQuad) -> Homography {
        let values = Homography.solve(source: DocumentRectifier.unitSquareCorners, targets: quad.points)!
        return Homography(values: values)
    }

    // MARK: - 契约用例

    @Test("不规则凸四边形（歪斜名片）：逐点一致，且四角精确落在四角映射位置")
    func irregularQuad() {
        let quad = DocumentQuad(
            topLeft: CGPoint(x: 0.20, y: 0.14),
            topRight: CGPoint(x: 0.86, y: 0.22),
            bottomRight: CGPoint(x: 0.78, y: 0.88),
            bottomLeft: CGPoint(x: 0.12, y: 0.80)
        )
        let homography = Self.homography(for: quad)
        let width = 340
        let height = 260
        Self.expectEquivalent(homography: homography, width: width, height: height)

        let grid = DocumentRectifier.samplingGrid(homography: homography, targetWidth: width, targetHeight: height)
        func toUnit(_ point: (x: Float, y: Float)) -> CGPoint {
            CGPoint(x: Double((point.x + 1) / 2), y: Double((point.y + 1) / 2))
        }
        let corners: [(Int, Int, CGPoint)] = [
            (0, 0, quad.topLeft),
            (width - 1, 0, quad.topRight),
            (width - 1, height - 1, quad.bottomRight),
            (0, height - 1, quad.bottomLeft),
        ]
        for (column, row, expected) in corners {
            let mapped = toUnit(try! #require(grid.point(column: column, row: row)))
            #expect(abs(mapped.x - expected.x) < 1e-5)
            #expect(abs(mapped.y - expected.y) < 1e-5)
        }
    }

    @Test("轴对齐矩形：逐点一致")
    func axisAlignedQuad() {
        let quad = DocumentQuad(
            topLeft: CGPoint(x: 0.1, y: 0.1),
            topRight: CGPoint(x: 0.9, y: 0.1),
            bottomRight: CGPoint(x: 0.9, y: 0.9),
            bottomLeft: CGPoint(x: 0.1, y: 0.9)
        )
        Self.expectEquivalent(homography: Self.homography(for: quad), width: 200, height: 150)
    }

    @Test("整幅四角（恒等）：逐点一致，且网格等于单位网格")
    func identityGrid() {
        let quad = DocumentQuad(
            topLeft: CGPoint(x: 0, y: 0),
            topRight: CGPoint(x: 1, y: 0),
            bottomRight: CGPoint(x: 1, y: 1),
            bottomLeft: CGPoint(x: 0, y: 1)
        )
        let homography = Self.homography(for: quad)
        Self.expectEquivalent(homography: homography, width: 64, height: 48)
        let grid = DocumentRectifier.samplingGrid(homography: homography, targetWidth: 64, targetHeight: 48)
        let identity = NormalizedSampleGrid.identity(columns: 64, rows: 48)
        #expect(Self.maxAbsoluteDifference(grid, identity) < 1e-6)
    }

    @Test("旋转四角（含非轴对齐）：逐点一致")
    func rotatedQuad() {
        // 绕中心旋转 12°，边长各 0.6 / 0.5。
        let angle = 12.0 * Double.pi / 180
        let cosine = cos(angle)
        let sine = sin(angle)
        let halfWidth = 0.3
        let halfHeight = 0.25
        func placed(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: 0.5 + cosine * x - sine * y, y: 0.5 + sine * x + cosine * y)
        }
        let quad = DocumentQuad(
            topLeft: placed(-halfWidth, -halfHeight),
            topRight: placed(halfWidth, -halfHeight),
            bottomRight: placed(halfWidth, halfHeight),
            bottomLeft: placed(-halfWidth, halfHeight)
        )
        Self.expectEquivalent(homography: Self.homography(for: quad), width: 180, height: 120)
    }

    @Test("极窄目标尺寸（1×N / N×1 / 1×1）：逐点一致（unit 的 count == 1 分支）")
    func degenerateTargetSizes() {
        let quad = DocumentQuad(
            topLeft: CGPoint(x: 0.2, y: 0.2),
            topRight: CGPoint(x: 0.8, y: 0.3),
            bottomRight: CGPoint(x: 0.7, y: 0.9),
            bottomLeft: CGPoint(x: 0.1, y: 0.8)
        )
        let homography = Self.homography(for: quad)
        Self.expectEquivalent(homography: homography, width: 1, height: 37)
        Self.expectEquivalent(homography: homography, width: 37, height: 1)
        Self.expectEquivalent(homography: homography, width: 1, height: 1)
    }

    @Test("分母过零的退化单应：触发 1e-12 保护路径后仍逐点一致")
    func denominatorGuard() {
        // den = -u - v + 1 → 在 (u, v) = (0.5, 0.5)（网格中心）恰好为 0。
        let homography = Homography(values: [0, 0, 0, 0, 0, 0, -1, -1])
        Self.expectEquivalent(homography: homography, width: 101, height: 101)
    }

    @Test("真实量级（≈1.08 M 点）：逐点一致（列/行混用会在这里暴露）")
    func realisticScale() {
        let quad = DocumentQuad(
            topLeft: CGPoint(x: 0.06, y: 0.04),
            topRight: CGPoint(x: 0.93, y: 0.09),
            bottomRight: CGPoint(x: 0.88, y: 0.95),
            bottomLeft: CGPoint(x: 0.03, y: 0.90)
        )
        Self.expectEquivalent(homography: Self.homography(for: quad), width: 900, height: 1200)
    }
}
