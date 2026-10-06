// GridIdentityDeviation —— 采样网格相对「恒等网格」的偏离度量（纯几何，平台无关）。
//
// 背景（批 26）：大象反馈 UVDoc 的头号问题 ——「没有畸变（只有几何变形）时 UVDoc 也会当做有畸变来处理」。
// 已经在 Core Image 侧做过透视矫正、页面本来平整的图（单据 / 名片 / 平放纸），UVDoc 仍会给出一张
// 非恒等的采样网格，于是被「多掰一道」。本文件提供「网格离恒等有多远」的度量，供恒等门控判据使用。
//
// ⚠️ 口径（必须遵守）：度量的入参必须是**即将用于重采样的那张网格** —— 即已经过
// `extendedToCoverSource()` 的「覆盖整幅源图」网格。UVDoc 原始网格常只覆盖源图一个子矩形
// （各边内缩 1.3%–6.0%，批 20 实测），直接拿原始网格算会把这个内缩当成形变，度量失效。
//
// 坐标约定沿用 `GridResampler`：归一化坐标 ∈ [-1, 1]，`align_corners=True`（-1 → 像素 0、
// +1 → 像素 N-1）。纯函数：不改入参、不采样像素、不碰 AppLog。
import Foundation

/// 采样网格相对同分辨率恒等网格的偏离（逐点位移向量的模长统计）。
public struct GridIdentityDeviation: Equatable, Sendable {
    /// 逐点位移向量模长的最大值（归一化 [-1, 1] 尺度）。
    public let maximumMagnitude: Float
    /// 逐点位移向量模长的均方根。
    public let rmsMagnitude: Float

    public init(maximumMagnitude: Float, rmsMagnitude: Float) {
        self.maximumMagnitude = maximumMagnitude
        self.rmsMagnitude = rmsMagnitude
    }
}

extension NormalizedSampleGrid {
    /// 本网格逐点相对 `identity(columns:rows:)` 的偏离。
    ///
    /// **⚠️ 入参必须是即将用于重采样的网格（已 `extendedToCoverSource()`）**，否则 UVDoc 原始网格的
    /// 内缩会被误判成形变（内缩不是畸变，是「网格没铺满」）。
    ///
    /// - 位移 = 本网格逐点坐标 − 恒等网格同点坐标（同一 `[-1, 1]` / `align_corners=True` 约定）。
    /// - 任一坐标 `!isFinite` → 返回 **nil**（退化，交给调用方保守处理）。
    /// - 恒等网格 → `maximumMagnitude == 0 && rmsMagnitude == 0`（浮点精确 0）。
    /// - 纯函数：不改入参、不采样像素、不碰 AppLog。
    public func deviationFromIdentity() -> GridIdentityDeviation? {
        let identity = NormalizedSampleGrid.identity(columns: columns, rows: rows)
        let count = columns * rows
        var maximum: Float = 0
        var sumOfSquares = 0.0
        for index in 0 ..< count {
            let x = xValues[index]
            let y = yValues[index]
            guard x.isFinite, y.isFinite else { return nil }
            let dx = x - identity.xValues[index]
            let dy = y - identity.yValues[index]
            let magnitude = (dx * dx + dy * dy).squareRoot()
            maximum = max(maximum, magnitude)
            sumOfSquares += Double(magnitude) * Double(magnitude)
        }
        return GridIdentityDeviation(
            maximumMagnitude: maximum,
            rmsMagnitude: Float((sumOfSquares / Double(count)).squareRoot())
        )
    }
}
