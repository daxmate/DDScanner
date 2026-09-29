// Homography —— 四角 → 单位正方形的单应矩阵（占位，见 docs/architecture.md）。
import CoreGraphics
import Foundation

/// 3×3 单应矩阵（行优先，h22 归一为 1）。
public struct Homography: Equatable, Sendable {
    public let values: [Double]

    public init?(mapping quad: DocumentQuad) {
        let targets: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 1, y: 1),
            CGPoint(x: 0, y: 1),
        ]
        guard let solved = Self.solve(source: quad.points, targets: targets) else { return nil }
        self.values = solved
    }

    public init(values: [Double]) {
        self.values = values
    }

    public func map(_ point: CGPoint) -> CGPoint {
        let denominator = values[6] * Double(point.x) + values[7] * Double(point.y) + 1
        let safe = abs(denominator) < 1e-12 ? 1e-12 : denominator
        let x = (values[0] * Double(point.x) + values[1] * Double(point.y) + values[2]) / safe
        let y = (values[3] * Double(point.x) + values[4] * Double(point.y) + values[5]) / safe
        return CGPoint(x: x, y: y)
    }

    /// 解 8 元线性方程组（高斯消元 + 部分主元）；奇异时返回 nil。
    static func solve(source: [CGPoint], targets: [CGPoint]) -> [Double]? {
        var matrix = [[Double]]()
        for index in 0 ..< 4 {
            let sourceX = Double(source[index].x)
            let sourceY = Double(source[index].y)
            let targetX = Double(targets[index].x)
            let targetY = Double(targets[index].y)
            matrix.append([sourceX, sourceY, 1, 0, 0, 0, -targetX * sourceX, -targetX * sourceY, targetX])
            matrix.append([0, 0, 0, sourceX, sourceY, 1, -targetY * sourceX, -targetY * sourceY, targetY])
        }
        let size = matrix.count
        for column in 0 ..< size {
            var pivot = column
            for row in (column + 1) ..< size where abs(matrix[row][column]) > abs(matrix[pivot][column]) {
                pivot = row
            }
            guard abs(matrix[pivot][column]) > 1e-12 else { return nil }
            matrix.swapAt(column, pivot)
            let lead = matrix[column][column]
            for index in column ..< (size + 1) { matrix[column][index] /= lead }
            for row in 0 ..< size where row != column {
                let factor = matrix[row][column]
                guard factor != 0 else { continue }
                for index in column ..< (size + 1) { matrix[row][index] -= factor * matrix[column][index] }
            }
        }
        return matrix.map { $0[size] }
    }
}
