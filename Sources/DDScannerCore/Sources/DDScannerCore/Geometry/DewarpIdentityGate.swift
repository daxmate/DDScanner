// DewarpIdentityGate —— 去畸变「恒等门控」纯策略（平台无关）。
//
// 背景（批 26）：把 UVDoc 输出网格与同分辨率恒等网格比对，位移小到阈值以下就判为
// 「无需非线性矫正」→ 跳过重采样，直接用透视矫正后的图。本文件只是**判据**（纯策略），
// 度量在 `GridIdentityDeviation`，重采样仍只有 `GridResampler` 一个入口。
//
// ⚠️ 入参必须是**即将用于重采样的网格** —— 即已经过 `extendedToCoverSource()` 的「覆盖整幅源图」
// 网格。UVDoc 原始网格常只覆盖源图一个子矩形（各边内缩 1.3%–6.0%），直接拿原始网格判据
// 会把这个内缩误判成形变，门控失效。
import Foundation

/// 恒等门控：按「网格相对恒等网格的最大位移」与阈值比较，决定是否跳过去畸变重采样。
public struct DewarpIdentityGate: Equatable, Sendable {
    /// 判据阈值（归一化 [-1, 1] 尺度）；负数钳到 0。
    public let threshold: Float

    public init(threshold: Float) {
        self.threshold = max(threshold, 0)
    }

    /// 门控结论。
    public enum Decision: Equatable, Sendable {
        /// 位移 ≤ 阈值 → 判为无需去畸变（跳过重采样）。
        case bypass(GridIdentityDeviation)
        /// 位移 > 阈值 → 正常去畸变。
        case dewarp(GridIdentityDeviation)
        /// 网格度量不可用（`deviationFromIdentity()` 为 nil）→ **保守不动作**（也走「跳过」）。
        case indeterminate
    }

    /// 对**即将用于重采样**的网格给出结论。
    ///
    /// **⚠️ 入参必须是即将用于重采样的网格（已 `extendedToCoverSource()`）**，否则 UVDoc 原始网格的
    /// 内缩会被误判成形变 —— 内缩本身不代表弯曲，判据会失效。
    ///
    /// - `deviation.maximumMagnitude <= threshold` → `.bypass`（**边界值算 bypass**）。
    /// - 否则 → `.dewarp`。
    /// - `deviationFromIdentity() == nil` → `.indeterminate`。
    public func decide(for grid: NormalizedSampleGrid) -> Decision {
        guard let deviation = grid.deviationFromIdentity() else { return .indeterminate }
        return deviation.maximumMagnitude <= threshold ? .bypass(deviation) : .dewarp(deviation)
    }
}
