// FrontEndPlanner —— 前段（检测 → 透视矫正）的**可降级**决策（纯逻辑，平台无关）。
//
// 为什么单独成层：真机里「检测不到文档」是常态（背景杂乱 / 低对比），页面与管线都必须**回退整帧
// 直接去畸变**、且**不得抛错、不得崩**。把这条降级契约收成一个永不抛错的纯函数，就能在本机
// `swift test` 里守住（见 DocumentRectifierTests 的 FrontEndPlanner 用例）。
import CoreGraphics
import Foundation

/// 前段决策结果：检测（可为 nil = 未检测到）与矫正方案（可为 nil = 回退整帧）。
public struct FrontEndDecision: Equatable, Sendable {
    /// 检测结果；nil = 后端没找到文档。
    public let detection: DocumentDetection?
    /// 矫正方案；nil = **回退**（不裁切、不透视矫正，直接对整帧去畸变）。
    public let rectification: RectificationPlan?

    public init(detection: DocumentDetection?, rectification: RectificationPlan?) {
        self.detection = detection
        self.rectification = rectification
    }

    /// 是否走了回退路径。
    public var isFallback: Bool { rectification == nil }
}

/// 前段决策：把「检测结果 + 源图尺寸」折算成「矫正方案或回退」。
public enum FrontEndPlanner {
    /// 永不抛错：检测缺失、四角退化（重合 / 共线 / 非凸 / 越界）或单应不可解，一律回退整帧。
    public static func decide(
        detection: DocumentDetection?,
        sourceSize: CGSize,
        scale: Double = 1
    ) -> FrontEndDecision {
        guard let detection,
              let plan = try? DocumentRectifier.plan(quad: detection.quad, sourceSize: sourceSize, scale: scale) else {
            return FrontEndDecision(detection: detection, rectification: nil)
        }
        return FrontEndDecision(detection: detection, rectification: plan)
    }
}
