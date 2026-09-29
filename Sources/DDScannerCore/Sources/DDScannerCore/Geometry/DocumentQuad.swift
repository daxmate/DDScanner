// DocumentQuad —— 文档四角几何（占位，见 docs/architecture.md）。
import CoreGraphics
import Foundation

/// 一份文档在画面中的四个角点，按 左上 → 右上 → 右下 → 左下 顺序存放。
public struct DocumentQuad: Equatable, Sendable {
    public var topLeft: CGPoint
    public var topRight: CGPoint
    public var bottomRight: CGPoint
    public var bottomLeft: CGPoint

    public init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    /// 按 左上 → 右上 → 右下 → 左下 顺序枚举。
    public var points: [CGPoint] {
        [topLeft, topRight, bottomRight, bottomLeft]
    }

    public var isDegenerate: Bool {
        Set(points.map { "\($0.x),\($0.y)" }).count < 4
    }

    /// 归一化到给定画布尺寸（0...1）。
    public func normalized(in size: CGSize) -> DocumentQuad {
        let width = max(size.width, .ulpOfOne)
        let height = max(size.height, .ulpOfOne)
        func unit(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x / width, y: point.y / height)
        }
        return DocumentQuad(
            topLeft: unit(topLeft),
            topRight: unit(topRight),
            bottomRight: unit(bottomRight),
            bottomLeft: unit(bottomLeft)
        )
    }

    /// 由任意顺序的四点恢复出 TL → TR → BR → BL 顺序；无法判定时返回 nil。
    public static func ordered(_ raw: [CGPoint]) -> DocumentQuad? {
        guard raw.count == 4 else { return nil }
        let sorted = raw.sorted { lhs, rhs in
            lhs.y == rhs.y ? lhs.x < rhs.x : lhs.y < rhs.y
        }
        let topRow = Array(sorted[0 ... 1]).sorted { $0.x < $1.x }
        let bottomRow = Array(sorted[2 ... 3]).sorted { $0.x < $1.x }
        let quad = DocumentQuad(
            topLeft: topRow[0],
            topRight: topRow[1],
            bottomRight: bottomRow[1],
            bottomLeft: bottomRow[0]
        )
        return quad.isDegenerate ? nil : quad
    }
}
