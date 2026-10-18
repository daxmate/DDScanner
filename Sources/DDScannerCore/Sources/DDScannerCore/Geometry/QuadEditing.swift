// QuadEditing —— 四角拖拽微调的纯几何助手（平台无关，见 docs/architecture.md 批 B2）。
//
// 只允许 import CoreGraphics / Foundation，禁 UIKit / SwiftUI：映射、夹紧、合法性判定都必须能脱离
// 模拟器在本机 swift test 验证。App 层的 QuadEditorView 只做呈现与手势，不得复制本文件的
// 映射 / 校验逻辑（单一实现）。
//
// 坐标约定（与 DocumentQuad 一致，写死）：四角为归一化坐标 ∈ [0,1]，原点在图像左上角、
// y 轴向下，顺序 TL → TR → BR → BL。
import CoreGraphics
import Foundation

/// 四角拖拽微调的几何工具集。
public enum QuadEditing {
    /// 角点索引，顺序与 DocumentQuad 存储顺序一致：左上 → 右上 → 右下 → 左下。
    public enum Corner: Int, CaseIterable, Sendable {
        case topLeft = 0
        case topRight = 1
        case bottomRight = 2
        case bottomLeft = 3

        /// 读取该角在给定四边形里的坐标。
        public func point(in quad: DocumentQuad) -> CGPoint {
            switch self {
            case .topLeft: return quad.topLeft
            case .topRight: return quad.topRight
            case .bottomRight: return quad.bottomRight
            case .bottomLeft: return quad.bottomLeft
            }
        }

        /// 用新坐标替换该角，返回新的四边形（不改入参）。
        public func replacing(_ point: CGPoint, in quad: DocumentQuad) -> DocumentQuad {
            var copy = quad
            switch self {
            case .topLeft: copy.topLeft = point
            case .topRight: copy.topRight = point
            case .bottomRight: copy.bottomRight = point
            case .bottomLeft: copy.bottomLeft = point
            }
            return copy
        }

        /// 沿边与该角相邻的两个角（用于「与相邻角保持最小距离」的夹紧）。
        public var adjacent: (Corner, Corner) {
            switch self {
            case .topLeft: return (.topRight, .bottomLeft)
            case .topRight: return (.bottomRight, .topLeft)
            case .bottomRight: return (.bottomLeft, .topRight)
            case .bottomLeft: return (.topLeft, .bottomRight)
            }
        }
    }

    /// 拖拽夹紧参数。
    public struct ClampConfig: Equatable, Sendable {
        /// 相邻角最小距离（像素）。0 = 不限制。
        public let minimumAdjacentDistance: CGFloat

        public init(minimumAdjacentDistance: CGFloat) {
            self.minimumAdjacentDistance = max(0, minimumAdjacentDistance)
        }

        /// 推荐参数：相邻角最小距离 = 图片短边的 2%。
        public static func recommended(forImageSize size: CGSize) -> ClampConfig {
            let shortEdge = max(min(size.width, size.height), 1)
            return ClampConfig(minimumAdjacentDistance: shortEdge * 0.02)
        }
    }

    /// 合法性判定的可诊断原因（供 UI 映射一行文案）。
    public enum ValidityIssue: Equatable, Sendable {
        /// 有角点重合（三点或四点不唯一）。
        case degenerate
        /// 四点不构成严格凸四边形（含三点共线）。
        case nonConvex
        /// 四边形面积低于下限（相对图片面积的比例）。
        case areaTooSmall(minimumRatio: Double)
    }

    /// 面积下限默认值：四边形面积 ≥ 图片面积的 2%。
    public static let defaultMinimumAreaRatio = 0.02

    // MARK: - aspect-fit 映射

    /// 图片像素 / 归一化坐标 ↔ 显示矩形内视图坐标的双向映射（含 letterbox 偏移）。
    ///
    /// displayRect 是命名坐标空间里容纳图片的完整矩形；图片在其中按 aspect-fit 居中，两侧
    /// （或上下）的留白即 letterbox，全部由本类型换算，调用方不需要手工算。
    public struct AspectFitMapping: Equatable, Sendable {
        public let imageSize: CGSize
        public let displayRect: CGRect

        public init(imageSize: CGSize, displayRect: CGRect) {
            self.imageSize = CGSize(
                width: max(imageSize.width, .ulpOfOne),
                height: max(imageSize.height, .ulpOfOne)
            )
            self.displayRect = displayRect
        }

        /// 图片到视图的缩放比（视图点 / 像素）。
        public var scale: CGFloat {
            let imageAspect = imageSize.width / imageSize.height
            let rectAspect = displayRect.width / max(displayRect.height, .ulpOfOne)
            if imageAspect > rectAspect {
                return displayRect.width / imageSize.width
            }
            return displayRect.height / imageSize.height
        }

        /// 图片显示后的视图尺寸。
        public var displayedSize: CGSize {
            CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        }

        /// 图片左上角在显示矩形里的视图坐标（letterbox 偏移后的内容原点）。
        public var contentOrigin: CGPoint {
            CGPoint(
                x: displayRect.minX + (displayRect.width - displayedSize.width) / 2,
                y: displayRect.minY + (displayRect.height - displayedSize.height) / 2
            )
        }

        /// 像素 → 视图。
        public func viewPoint(forPixel point: CGPoint) -> CGPoint {
            CGPoint(x: contentOrigin.x + point.x * scale, y: contentOrigin.y + point.y * scale)
        }

        /// 视图 → 像素。
        public func pixelPoint(forView point: CGPoint) -> CGPoint {
            CGPoint(x: (point.x - contentOrigin.x) / scale, y: (point.y - contentOrigin.y) / scale)
        }

        /// 归一化 → 像素。
        public func pixelPoint(forNormalized point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * imageSize.width, y: point.y * imageSize.height)
        }

        /// 像素 → 归一化。
        public func normalizedPoint(forPixel point: CGPoint) -> CGPoint {
            CGPoint(x: point.x / imageSize.width, y: point.y / imageSize.height)
        }

        /// 归一化 → 视图。
        public func viewPoint(forNormalized point: CGPoint) -> CGPoint {
            viewPoint(forPixel: pixelPoint(forNormalized: point))
        }

        /// 视图 → 归一化。
        public func normalizedPoint(forView point: CGPoint) -> CGPoint {
            normalizedPoint(forPixel: pixelPoint(forView: point))
        }
    }

    // MARK: - 拖拽夹紧

    /// 把「正在拖动的角」夹紧到合法位置，返回新的四边形（归一化坐标）。
    ///
    /// 夹紧分三步（全部在像素空间算，因为相邻角最小距离是像素欧氏距离）：
    /// 1. 钳制到图片边界内；2. 与两个相邻角保持最小距离；3. 外推后可能又越界，再钳制一次。
    ///
    /// - Parameters:
    ///   - quad: 当前四边形（归一化）。
    ///   - corner: 正在拖动的角。
    ///   - proposed: 手势给出的目标位置（归一化）。
    ///   - imageSize: 图片像素尺寸（用于像素空间换算）。
    ///   - config: 夹紧参数（最小相邻距离，像素）。
    public static func clamp(
        _ quad: DocumentQuad,
        moving corner: Corner,
        to proposed: CGPoint,
        imageSize: CGSize,
        config: ClampConfig
    ) -> DocumentQuad {
        let width = max(imageSize.width, .ulpOfOne)
        let height = max(imageSize.height, .ulpOfOne)
        let size = CGSize(width: width, height: height)

        let pixelQuad = quad.denormalized(in: size)
        var target = CGPoint(x: proposed.x * width, y: proposed.y * height)

        // 1) 钳制到图片边界内。
        target.x = min(max(target.x, 0), width)
        target.y = min(max(target.y, 0), height)

        // 2) 与两个相邻角保持最小距离（沿「相邻角 → 目标点」方向外推）。
        for neighbor in [corner.adjacent.0, corner.adjacent.1] {
            let neighborPoint = neighbor.point(in: pixelQuad)
            target = Self.push(target, awayFrom: neighborPoint, minimumDistance: config.minimumAdjacentDistance)
        }

        // 3) 外推可能把点推出边界，收尾再钳制一次。
        target.x = min(max(target.x, 0), width)
        target.y = min(max(target.y, 0), height)

        return corner.replacing(target, in: pixelQuad).normalized(in: size)
    }

    /// 若 point 距 anchor 小于 minimumDistance，沿 anchor → point 方向外推到最小距离。
    private static func push(_ point: CGPoint, awayFrom anchor: CGPoint, minimumDistance: CGFloat) -> CGPoint {
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        let distance = hypot(dx, dy)
        // 与相邻角重合：方向不定，保持原位（实际拖拽不会产生精确重合）。
        guard distance > 0 else { return point }
        guard distance < minimumDistance else { return point }
        let factor = minimumDistance / distance
        return CGPoint(x: anchor.x + dx * factor, y: anchor.y + dy * factor)
    }

    // MARK: - 合法性判定

    /// 判定四角是否可用（归一化坐标）。
    ///
    /// 检查顺序即诊断顺序：重合 → 非凸（含共线）→ 面积过小。返回 nil 表示合法。
    ///
    /// - Parameters:
    ///   - quad: 待判定四边形（归一化）。
    ///   - minimumAreaRatio: 面积下限（相对图片面积的比例，图片归一化面积为 1）。
    public static func validate(
        _ quad: DocumentQuad,
        minimumAreaRatio: Double = QuadEditing.defaultMinimumAreaRatio
    ) -> ValidityIssue? {
        if quad.isDegenerate {
            return .degenerate
        }
        if !quad.isConvex {
            return .nonConvex
        }
        if quad.area < max(minimumAreaRatio, 0) {
            return .areaTooSmall(minimumRatio: minimumAreaRatio)
        }
        return nil
    }
}
