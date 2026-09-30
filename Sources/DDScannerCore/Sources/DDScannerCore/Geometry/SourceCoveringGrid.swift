// SourceCoveringGrid —— 「覆盖整幅源图」的采样网格扩展（纯几何，平台无关）。
//
// 背景（批 19 spike 结论，见 memory/DDScanner/surveys/DDScanner-batch19-spike.md）：
// UVDoc 输出的网格坐标范围**只覆盖源图的一个子矩形**（各边内缩 1.3%–6.0%）；而重采样画布仍按
// 「输出尺寸 = 源图尺寸」铺满 ⇒ 源图四条边条从未被采样（产品路径上 9.4%–14.1% 的像素丢失）。
// 修法（FIX-A，已实测四边丢失 → 0.0 px）：沿边界斜率**线性外推**网格直到覆盖整幅源图
// （归一化 [-1,1]²），再**按轴仿射归一化**到恰好 [-1,1]，照旧走 `GridResampler.resample`。
//
// 语义边界（**不新增第二份重采样实现**）：
//   - 本文件只做**网格坐标数学**（外推 + 归一化），不采样任何像素；
//   - 采样仍只有 `GridResampler` / `AcceleratedGridResampler` 一个入口；
//   - **已覆盖 [-1,1]² 的网格（恒等网格、铺满的透视矫正网格）→ 原样返回（无副作用 no-op）**；
//   - 退化输入（非有限值 / 单点 / 零跨度）→ 原样返回，绝不崩、绝不去归一化除零。
//
// 坐标约定沿用 `GridResampler`：归一化坐标 ∈ [-1, 1]，`-1 → 像素 0`、`+1 → 像素 (N-1)`
// （PyTorch `grid_sample` 的 `align_corners=True`）。
import Foundation

/// `NormalizedSampleGrid` 的「覆盖整幅源图」扩展。
extension NormalizedSampleGrid {
    /// 返回一个覆盖整幅源图（归一化 `[-1, 1]²`）的采样网格：
    /// 沿边界斜率线性外推至覆盖整幅源图，再按轴仿射归一化到恰好 `[-1, 1]²`。
    ///
    /// - 若网格**已经**覆盖 `[-1, 1]²`（例如 `identity`、铺满的透视矫正网格）→ 原样返回
    ///   （逐点相等，不重采样、不改数值）；退化或含非有限值同样原样返回。
    /// - 外推只发生在**原本一个像素都没采到的边条**上：内部坐标只经历一个按轴仿射
    ///   （缩放 + 平移），形状不变；坐标范围被归一化到 `[-1, 1]`，故四边内容不再被裁掉。
    ///
    /// 该函数是纯网格运算（不触碰像素），采样请继续走 `GridResampler.resample(grid:source:)`。
    public func extendedToCoverSource() -> NormalizedSampleGrid {
        guard let coverage = SourceCoveringGrid.coverage(of: self) else { return self }
        if coverage.coversUnitSquare { return self }
        let extrapolated = SourceCoveringGrid.extrapolate(self, coverage: coverage)
        return SourceCoveringGrid.renormalize(extrapolated)
    }
}

/// 网格覆盖范围与两步修复（外推 / 归一化）的实现细节；对外只暴露上面的 `extendedToCoverSource()`。
enum SourceCoveringGrid {
    /// 归一化坐标下的「已覆盖」判定容差（≈ 亚像素级；避免浮点末位差触发无谓的重新归一化）。
    static let coverageEpsilon: Float = 1e-6
    /// 边界斜率小于此值视为「平边」，不参与外推（防止近乎水平的边把行数推爆）。
    static let slopeEpsilon: Float = 1e-6
    /// 外推余量：按需要的行/列数上取整后再乘 1.02，确保外推后**严格覆盖** `[-1, 1]²`。
    static let extrapolationMargin: Float = 1.02

    /// 遍历网格得到的坐标范围。
    struct Coverage: Equatable {
        var xmin: Float = .greatestFiniteMagnitude
        var xmax: Float = -.greatestFiniteMagnitude
        var ymin: Float = .greatestFiniteMagnitude
        var ymax: Float = -.greatestFiniteMagnitude

        var xRange: Float { xmax - xmin }
        var yRange: Float { ymax - ymin }

        /// 是否已覆盖整幅源图（`[-1, 1]²`，含容差）。
        var coversUnitSquare: Bool {
            xmin <= -1 + coverageEpsilon && xmax >= 1 - coverageEpsilon
                && ymin <= -1 + coverageEpsilon && ymax >= 1 - coverageEpsilon
        }
    }

    /// 网格坐标范围；含非有限值 → nil；跨度为零（单点 / 共线）→ nil（一律按退化处理，调用方原样返回）。
    static func coverage(of grid: NormalizedSampleGrid) -> Coverage? {
        var xmin = Float.greatestFiniteMagnitude
        var xmax = -Float.greatestFiniteMagnitude
        var ymin = Float.greatestFiniteMagnitude
        var ymax = -Float.greatestFiniteMagnitude
        for index in 0 ..< (grid.columns * grid.rows) {
            let x = grid.xValues[index]
            let y = grid.yValues[index]
            guard x.isFinite, y.isFinite else { return nil }
            xmin = min(xmin, x)
            xmax = max(xmax, x)
            ymin = min(ymin, y)
            ymax = max(ymax, y)
        }
        let range = Coverage(xmin: xmin, xmax: xmax, ymin: ymin, ymax: ymax)
        guard range.xRange > coverageEpsilon, range.yRange > coverageEpsilon else { return nil }
        return range
    }

    /// 沿边界斜率线性外推：先在行方向（上/下）加行，再在列方向（左/右）加列。
    static func extrapolate(_ grid: NormalizedSampleGrid, coverage _: Coverage) -> NormalizedSampleGrid {
        let rows = grid.rows
        let columns = grid.columns

        func x(_ row: Int, _ column: Int) -> Float { grid.xValues[row * columns + column] }
        func y(_ row: Int, _ column: Int) -> Float { grid.yValues[row * columns + column] }

        // ── 行方向需要外推的行数（逐列求最大） ─────────────────────────────
        var topCount = 0
        var bottomCount = 0
        if rows >= 2 {
            for column in 0 ..< columns {
                let topY = y(0, column)
                let topSlope = y(1, column) - topY
                if topY > -1, topSlope > slopeEpsilon {
                    topCount = max(topCount, steps(from: topY, to: -1, slope: topSlope))
                }
                let bottomY = y(rows - 1, column)
                let bottomSlope = bottomY - y(rows - 2, column)
                if bottomY < 1, bottomSlope > slopeEpsilon {
                    bottomCount = max(bottomCount, steps(from: bottomY, to: 1, slope: bottomSlope))
                }
            }
        }
        // 上界：一行网格最多再复制自身规模，避免近乎平边时把输出撑爆（此时覆盖率可能略有不足，行为仍明确）。
        topCount = min(topCount, rows)
        bottomCount = min(bottomCount, rows)

        let middleRows = rows + topCount + bottomCount
        var rowX = [Float](repeating: 0, count: middleRows * columns)
        var rowY = [Float](repeating: 0, count: middleRows * columns)
        for column in 0 ..< columns {
            // 外推步长只在对应的外推行数 > 0 时才读邻居（`rows < 2` 时两者恒为 0，不会越界）。
            for index in 0 ..< topCount {
                let distance = Float(topCount - index)
                let topX = x(0, column)
                let topY = y(0, column)
                rowX[index * columns + column] = topX - distance * (x(1, column) - topX)
                rowY[index * columns + column] = topY - distance * (y(1, column) - topY)
            }
            for row in 0 ..< rows {
                rowX[(topCount + row) * columns + column] = x(row, column)
                rowY[(topCount + row) * columns + column] = y(row, column)
            }
            for index in 0 ..< bottomCount {
                let distance = Float(index + 1)
                let bottomX = x(rows - 1, column)
                let bottomY = y(rows - 1, column)
                rowX[(topCount + rows + index) * columns + column] = bottomX + distance * (bottomX - x(rows - 2, column))
                rowY[(topCount + rows + index) * columns + column] = bottomY + distance * (bottomY - y(rows - 2, column))
            }
        }

        // ── 列方向需要外推的列数（逐行求最大，行覆盖外推后的整体） ─────────
        var leftCount = 0
        var rightCount = 0
        if columns >= 2 {
            for row in 0 ..< middleRows {
                let leftX = rowX[row * columns]
                let leftSlope = rowX[row * columns + 1] - leftX
                if leftX > -1, leftSlope > slopeEpsilon {
                    leftCount = max(leftCount, steps(from: leftX, to: -1, slope: leftSlope))
                }
                let rightX = rowX[row * columns + columns - 1]
                let rightSlope = rightX - rowX[row * columns + columns - 2]
                if rightX < 1, rightSlope > slopeEpsilon {
                    rightCount = max(rightCount, steps(from: rightX, to: 1, slope: rightSlope))
                }
            }
        }
        leftCount = min(leftCount, columns)
        rightCount = min(rightCount, columns)

        let outColumns = columns + leftCount + rightCount
        var outX = [Float](repeating: 0, count: middleRows * outColumns)
        var outY = [Float](repeating: 0, count: middleRows * outColumns)
        for row in 0 ..< middleRows {
            // 左/右外推列数 > 0 必然意味着 `columns >= 2`，故这里读邻居索引是安全的。
            for index in 0 ..< leftCount {
                let distance = Float(leftCount - index)
                let leftX = rowX[row * columns]
                let leftY = rowY[row * columns]
                outX[row * outColumns + index] = leftX - distance * (rowX[row * columns + 1] - leftX)
                outY[row * outColumns + index] = leftY - distance * (rowY[row * columns + 1] - leftY)
            }
            for column in 0 ..< columns {
                outX[row * outColumns + leftCount + column] = rowX[row * columns + column]
                outY[row * outColumns + leftCount + column] = rowY[row * columns + column]
            }
            for index in 0 ..< rightCount {
                let distance = Float(index + 1)
                let rightX = rowX[row * columns + columns - 1]
                let rightY = rowY[row * columns + columns - 1]
                let stepX = rightX - rowX[row * columns + columns - 2]
                let stepY = rightY - rowY[row * columns + columns - 2]
                outX[row * outColumns + leftCount + columns + index] = rightX + distance * stepX
                outY[row * outColumns + leftCount + columns + index] = rightY + distance * stepY
            }
        }

        return NormalizedSampleGrid(
            columns: outColumns,
            rows: middleRows,
            xValues: outX,
            yValues: outY
        )
    }

    /// 按轴仿射归一化：把当前坐标范围压到恰好 `[-1, 1]²`（只改采样比例，不改形变形状）。
    static func renormalize(_ grid: NormalizedSampleGrid) -> NormalizedSampleGrid {
        guard let coverage = coverage(of: grid) else { return grid }
        let xRange = coverage.xRange
        let yRange = coverage.yRange
        let xValues = grid.xValues.map { 2 * ($0 - coverage.xmin) / xRange - 1 }
        let yValues = grid.yValues.map { 2 * ($0 - coverage.ymin) / yRange - 1 }
        return NormalizedSampleGrid(
            columns: grid.columns,
            rows: grid.rows,
            xValues: xValues,
            yValues: yValues
        )
    }

    /// 从 `value` 出发、沿 `slope` 前进、跨到 `target` 所需的最少步数（乘余量后上取整）。
    ///
    /// `slope > 0`；`target > value` 时沿正方向前进，`target < value` 时沿负方向前进。
    private static func steps(from value: Float, to target: Float, slope: Float) -> Int {
        let distance = abs(target - value) / slope * extrapolationMargin
        return max(Int(distance.rounded(.up)), 1)
    }
}
