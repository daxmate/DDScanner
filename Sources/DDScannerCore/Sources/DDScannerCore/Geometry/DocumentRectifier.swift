// DocumentRectifier —— 四角 → 正面矩形（透视矫正 + 裁切）的纯几何（平台无关）。
//
// 为什么放在 Core：几何（单应求解、目标尺寸估算、采样网格生成）必须能脱离模拟器在本机
// `swift test` 验证（见 docs/architecture.md「为什么 Core 必须平台无关」）。像素重采样**不允许**
// 另写一份：一律走 `GridResampler`（产品路径唯一实现，见 docs/contract-register.md「参考实现」）。
//
// 坐标约定（与 `DocumentQuad` / `DocumentDetection` 一致，**写死**）：
//   四角为归一化坐标 ∈ [0,1]，原点在**图像左上角**、y 轴**向下**；顺序 **TL → TR → BR → BL**。
//   采样网格沿用 `GridResampler` 的 PyTorch `grid_sample` 约定：-1 → 像素 0，+1 → 像素 (N-1)。
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

    static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> Double {
        let dx = Double(rhs.x - lhs.x)
        let dy = Double(rhs.y - lhs.y)
        return (dx * dx + dy * dy).squareRoot()
    }
}
