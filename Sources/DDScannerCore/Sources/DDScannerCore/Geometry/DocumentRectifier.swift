// DocumentRectifier —— 四角 → 正面矩形（透视矫正 + 裁切）的纯几何（平台无关）。
//
// 为什么放在 Core：几何（单应求解、目标尺寸估算、采样网格生成）必须能脱离模拟器在本机
// `swift test` 验证（见 docs/architecture.md「为什么 Core 必须平台无关」）。像素重采样**不允许**
// 另写一份：一律走 `GridResampler`（产品路径唯一实现，见 docs/contract-register.md「参考实现」）。
//
// 坐标约定（与 `DocumentQuad` / `DocumentDetection` 一致，**写死**）：
//   四角为归一化坐标 ∈ [0,1]，原点在**图像左上角**、y 轴**向下**；顺序 **TL → TR → BR → BL**。
//   采样网格沿用 `GridResampler` 的 PyTorch `grid_sample` 约定：-1 → 像素 0，+1 → 像素 (N-1)。
import Accelerate
import CoreGraphics
import Foundation

/// 一次透视矫正的方案：输出尺寸 + 「目标像素 → 源图采样位置」的归一化采样网格。
public struct RectificationPlan: Equatable, Sendable {
    /// 输出（正面矩形）像素宽度。
    public let targetWidth: Int
    /// 输出（正面矩形）像素高度。
    public let targetHeight: Int
    /// 行优先采样网格，坐标 ∈ [-1, 1]（PyTorch `grid_sample` 约定）。
    public let samplingGrid: NormalizedSampleGrid

    public init(targetWidth: Int, targetHeight: Int, samplingGrid: NormalizedSampleGrid) {
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
        self.samplingGrid = samplingGrid
    }
}

/// 文档透视矫正：归一化四角 → 采样网格；像素重采样复用 `GridResampler`。
public enum DocumentRectifier {
    /// 退化面积下限（归一化坐标下）——低于它视为「三点共线 / 面积为零」。
    public static let minimumNormalizedArea = 1e-6

    /// 单位正方形的四个角（TL → TR → BR → BL，y 轴向下）。
    static let unitSquareCorners: [CGPoint] = [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 1, y: 0),
        CGPoint(x: 1, y: 1),
        CGPoint(x: 0, y: 1),
    ]

    /// 由归一化四角生成矫正方案（输出尺寸 + 采样网格）。
    ///
    /// - Parameters:
    ///   - quad: 文档在源图中的四角（归一化，TL→TR→BR→BL，左上原点）。
    ///   - sourceSize: 源图像素尺寸（用于把归一化边长换算成目标像素尺寸）。
    ///   - scale: 输出相对「文档实际像素尺寸」的缩放；默认 1 = 全分辨率。
    /// - Throws: `ScannerError.degenerateQuad`（重合 / 共线 / 非凸 / 面积为零 / 明显越界）
    ///   或 `ScannerError.homographyNotSolvable`（单应奇异）。
    public static func plan(quad: DocumentQuad, sourceSize: CGSize, scale: Double = 1) throws -> RectificationPlan {
        let quad = try validated(quad)
        let scale = max(scale, .ulpOfOne)

        // 目标尺寸：按文档两条对边的**最大**像素长度（全分辨率、不丢细节）。
        let pixelQuad = quad.denormalized(in: sourceSize)
        let width = max(distance(pixelQuad.topLeft, pixelQuad.topRight), distance(pixelQuad.bottomLeft, pixelQuad.bottomRight))
        let height = max(distance(pixelQuad.topLeft, pixelQuad.bottomLeft), distance(pixelQuad.topRight, pixelQuad.bottomRight))
        let targetWidth = max(Int((width * scale).rounded()), 1)
        let targetHeight = max(Int((height * scale).rounded()), 1)

        // 单应：**单位正方形 → 文档四角**（即「正面矩形坐标 → 源图归一化坐标」）。
        // 采样网格需要的就是这个方向：目标像素落在哪，就从源图哪里取。
        guard let values = Homography.solve(source: unitSquareCorners, targets: quad.points) else {
            throw ScannerError.homographyNotSolvable
        }
        let toSource = Homography(values: values)
        let grid = samplingGrid(homography: toSource, targetWidth: targetWidth, targetHeight: targetHeight)
        return RectificationPlan(targetWidth: targetWidth, targetHeight: targetHeight, samplingGrid: grid)
    }

    /// 按四角把源图矫正 + 裁切成正面矩形（全分辨率）；重采样走 `GridResampler` 唯一入口。
    public static func rectify(_ image: FloatImage, quad: DocumentQuad, scale: Double = 1) throws -> FloatImage {
        let plan = try plan(
            quad: quad,
            sourceSize: CGSize(width: image.width, height: image.height),
            scale: scale
        )
        return GridResampler.resample(
            grid: plan.samplingGrid,
            source: image,
            targetWidth: plan.targetWidth,
            targetHeight: plan.targetHeight
        )
    }

    // MARK: - 内部

    /// 校验四角：重合 / 共线 / 非凸 / 面积为零 / 明显越界 → `degenerateQuad`（fail-closed）。
    static func validated(_ quad: DocumentQuad) throws -> DocumentQuad {
        guard !quad.isDegenerate, quad.isConvex, quad.area > minimumNormalizedArea else {
            throw ScannerError.degenerateQuad
        }
        guard quad.isWithinUnitSquare(tolerance: 1e-6) else { throw ScannerError.degenerateQuad }
        return quad
    }

    /// 采样网格：目标像素 (column, row) → 源图归一化坐标（`align_corners=True` 口径）。
    ///
    /// 实现已**向量化**（Accelerate / vDSP，Double 精度）：单应映射写成「行内 u 向量的仿射变换 +
    /// 除法」——每行只做常数次向量调用（u 只依赖输出列，故列向量只建一次），把原逐像素双重循环
    /// （2689×3007 ≈ 8.08 M 次标量迭代）压成数千次向量调用。语义与标量实现**逐点一致**：
    /// 标量实现原样搬到测试侧作参考实现（`ScalarSamplingGridReference`），等价性由
    /// `SamplingGridEquivalenceTests` 守着（逐点 ≤ 1e-6）。
    ///
    /// 数值口径与原实现保持一致：u / v 仍以 Float 计算（`GridResampler.unit`）后再无损转 Double，
    /// 单应的乘法/加法结合序不变（`(h·u) + (h·v)` 后再加常数项），最后 `Float(x) * 2 - 1` 仍在
    /// Float 域做。唯一差异来自 vDSP 可能对 `a·b + c` 用 FMA → Double 级 ≤ 1 ULP，远小于契约阈值。
    static func samplingGrid(homography: Homography, targetWidth: Int, targetHeight: Int) -> NormalizedSampleGrid {
        precondition(targetWidth > 0 && targetHeight > 0, "目标尺寸必须为正")
        let width = targetWidth
        let height = targetHeight
        let values = homography.values
        let count = vDSP_Length(width)

        // 单应系数先取到局部标量（`vDSP_vsmsaD` 的标量参数需要指针）。
        let h0 = values[0], h1 = values[1], h2 = values[2], h3 = values[3]
        let h4 = values[4], h5 = values[5], h6 = values[6], h7 = values[7]
        var h0Scalar = h0, h2Scalar = h2, h3Scalar = h3
        var h5Scalar = h5, h6Scalar = h6
        var oneScalar: Double = 1

        // 列方向 u：只依赖输出列（与标量实现同为 Float 精度，再无损转 Double）。
        var unitColumns = [Float](repeating: 0, count: width)
        for column in 0 ..< width {
            unitColumns[column] = GridResampler.unit(column, count: width)
        }
        var uColumns = [Double](repeating: 0, count: width)
        vDSP_vspdp(unitColumns, 1, &uColumns, 1, count)

        var xValues = [Float](repeating: 0, count: width * height)
        var yValues = [Float](repeating: 0, count: width * height)

        // 行内中间量（长度 = 输出宽），循环内复用。
        var denominator = [Double](repeating: 0, count: width)
        var xNumerator = [Double](repeating: 0, count: width)
        var yNumerator = [Double](repeating: 0, count: width)
        var absoluteDenominator = [Double](repeating: 0, count: width)
        var coordinate = [Double](repeating: 0, count: width)
        var singleRow = [Float](repeating: 0, count: width)
        var twoScalar: Float = 2
        var negativeOneScalar: Float = -1

        xValues.withUnsafeMutableBufferPointer { xBuffer in
            yValues.withUnsafeMutableBufferPointer { yBuffer in
                for row in 0 ..< height {
                    // v 只依赖输出行；u / v 的取法与原实现完全相同。
                    let v = Double(GridResampler.unit(row, count: height))
                    // 与原实现同结合序：分母 ((h6·u) + (h7·v)) + 1；分子 ((h0·u) + (h1·v)) + h2。
                    var denominatorOffset = h7 * v
                    vDSP_vsmsaD(uColumns, 1, &h6Scalar, &denominatorOffset, &denominator, 1, count)
                    vDSP_vsaddD(denominator, 1, &oneScalar, &denominator, 1, count)
                    var xOffset = h1 * v
                    vDSP_vsmsaD(uColumns, 1, &h0Scalar, &xOffset, &xNumerator, 1, count)
                    vDSP_vsaddD(xNumerator, 1, &h2Scalar, &xNumerator, 1, count)
                    var yOffset = h4 * v
                    vDSP_vsmsaD(uColumns, 1, &h3Scalar, &yOffset, &yNumerator, 1, count)
                    vDSP_vsaddD(yNumerator, 1, &h5Scalar, &yNumerator, 1, count)

                    // 分母绝对值下界保护（与 `Homography.map` 的 1e-12 语义一致）：
                    // 正常单应恒走快速路径，退化时才对触发的元素逐个修正。
                    vDSP_vabsD(denominator, 1, &absoluteDenominator, 1, count)
                    var minimumAbsolute: Double = 0
                    vDSP_minmgvD(absoluteDenominator, 1, &minimumAbsolute, count)
                    if minimumAbsolute < 1e-12 {
                        for index in 0 ..< width where abs(denominator[index]) < 1e-12 {
                            denominator[index] = 1e-12
                        }
                    }

                    let base = row * width
                    // x = xNum / den → Float → [-1, 1]（`Float(x) * 2 - 1`）。
                    vDSP_vdivD(denominator, 1, xNumerator, 1, &coordinate, 1, count)
                    vDSP_vdpsp(coordinate, 1, &singleRow, 1, count)
                    vDSP_vsmul(singleRow, 1, &twoScalar, &singleRow, 1, count)
                    vDSP_vsadd(singleRow, 1, &negativeOneScalar, &singleRow, 1, count)
                    xBuffer.baseAddress!.advanced(by: base).update(from: singleRow, count: width)
                    // y 同理。
                    vDSP_vdivD(denominator, 1, yNumerator, 1, &coordinate, 1, count)
                    vDSP_vdpsp(coordinate, 1, &singleRow, 1, count)
                    vDSP_vsmul(singleRow, 1, &twoScalar, &singleRow, 1, count)
                    vDSP_vsadd(singleRow, 1, &negativeOneScalar, &singleRow, 1, count)
                    yBuffer.baseAddress!.advanced(by: base).update(from: singleRow, count: width)
                }
            }
        }
        return NormalizedSampleGrid(columns: width, rows: height, xValues: xValues, yValues: yValues)
    }

    static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> Double {
        let dx = Double(rhs.x - lhs.x)
        let dy = Double(rhs.y - lhs.y)
        return (dx * dx + dy * dy).squareRoot()
    }
}
