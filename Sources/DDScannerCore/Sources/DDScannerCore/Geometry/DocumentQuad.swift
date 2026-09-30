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

    /// 从归一化坐标（0...1）还原到给定画布尺寸（像素坐标）。`normalized(in:)` 的逆运算。
    public func denormalized(in size: CGSize) -> DocumentQuad {
        func pixel(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * size.width, y: point.y * size.height)
        }
        return DocumentQuad(
            topLeft: pixel(topLeft),
            topRight: pixel(topRight),
            bottomRight: pixel(bottomRight),
            bottomLeft: pixel(bottomLeft)
        )
    }

    /// 鞋带公式面积（取绝对值）；退化四角为 0。
    public var area: Double {
        abs(signedArea)
    }

    /// 鞋带公式有符号面积：顺时针为负、逆时针为正（本仓坐标原点在左上、y 轴向下）。
    public var signedArea: Double {
        var sum = 0.0
        for index in 0 ..< 4 {
            let current = points[index]
            let next = points[(index + 1) % 4]
            sum += Double(current.x) * Double(next.y) - Double(next.x) * Double(current.y)
        }
        return sum / 2
    }

    /// 严格凸判定：四个顶点的转向一致且**没有共线点**（共线 = 退化，直接判非凸）。
    public var isConvex: Bool {
        var positives = 0
        var negatives = 0
        for index in 0 ..< 4 {
            let a = points[index]
            let b = points[(index + 1) % 4]
            let c = points[(index + 2) % 4]
            let cross = Double(b.x - a.x) * Double(c.y - b.y)
                - Double(b.y - a.y) * Double(c.x - b.x)
            if abs(cross) < 1e-12 { return false }
            if cross > 0 { positives += 1 } else { negatives += 1 }
        }
        return positives == 4 || negatives == 4
    }

    /// 四个角点是否都落在单位正方形内（`tolerance` 为允许的越界量）。
    /// 检测端（Vision）给出的归一化四角应落在 [0,1]；明显的越界点视为不可信输入。
    public func isWithinUnitSquare(tolerance: Double = 0) -> Bool {
        let low = -abs(tolerance)
        let high = 1 + abs(tolerance)
        return points.allSatisfy { point in
            Double(point.x) >= low && Double(point.x) <= high
                && Double(point.y) >= low && Double(point.y) <= high
        }
    }

    /// 把每个角点钳制到单位正方形内（越界点贴边），用于检测输出的防御性收敛。
    public func clampedToUnitSquare() -> DocumentQuad {
        func clamp(_ point: CGPoint) -> CGPoint {
            CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        }
        return DocumentQuad(
            topLeft: clamp(topLeft),
            topRight: clamp(topRight),
            bottomRight: clamp(bottomRight),
            bottomLeft: clamp(bottomLeft)
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
