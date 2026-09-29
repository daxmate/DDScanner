// GridSampler —— 采样网格生成（占位，见 docs/architecture.md）。
// 去畸变模型的输出形态：目标图每个像素应当从源图哪个位置采样。
import CoreGraphics
import Foundation

/// 采样网格：`columns × rows` 个源图坐标，行优先存放。
public struct SampleGrid: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public let points: [CGPoint]

    public init(columns: Int, rows: Int, points: [CGPoint]) {
        precondition(points.count == columns * rows, "points 数量必须等于 columns × rows")
        self.columns = columns
        self.rows = rows
        self.points = points
    }

    public func point(column: Int, row: Int) -> CGPoint? {
        guard (0 ..< columns).contains(column), (0 ..< rows).contains(row) else { return nil }
        return points[row * columns + column]
    }
}

public enum GridSampler {
    /// 平面文档基线：在四角内做双线性插值（非线性畸变由去畸变后端覆盖）。
    public static func bilinear(within quad: DocumentQuad, columns: Int, rows: Int) -> SampleGrid {
        let columns = max(columns, 2)
        let rows = max(rows, 2)
        var points = [CGPoint]()
        points.reserveCapacity(columns * rows)
        for row in 0 ..< rows {
            let v = Double(row) / Double(rows - 1)
            for column in 0 ..< columns {
                let u = Double(column) / Double(columns - 1)
                points.append(interpolate(quad: quad, u: u, v: v))
            }
        }
        return SampleGrid(columns: columns, rows: rows, points: points)
    }

    static func interpolate(quad: DocumentQuad, u: Double, v: Double) -> CGPoint {
        let top = lerp(quad.topLeft, quad.topRight, u)
        let bottom = lerp(quad.bottomLeft, quad.bottomRight, u)
        return lerp(top, bottom, v)
    }

    static func lerp(_ start: CGPoint, _ end: CGPoint, _ t: Double) -> CGPoint {
        let x = Double(start.x) + (Double(end.x) - Double(start.x)) * t
        let y = Double(start.y) + (Double(end.y) - Double(start.y)) * t
        return CGPoint(x: x, y: y)
    }
}
