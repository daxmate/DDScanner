// GridResampler —— 归一化采样网格的重采样（Float32，平台无关）。
//
// 与上游 UVDoc `utils.bilinear_unwarping` 语义一致，分两步：
//   ① 把 45×31 的网格双线性插值到目标分辨率（`align_corners=True`）；
//   ② 按网格坐标从源图双线性采样（越界 **clamp**，不做零填充）。
//
// 网格坐标为归一化坐标（PyTorch `grid_sample` 约定）：`-1 → 像素 0`，`+1 → 像素 (N-1)`。
// 全程 Float32：FP16 网格坐标量化会把像素误差推到约 0.24 像素，这就是重采样不放进 Core ML
// 模型的原因（实测见 Tools/ModelConvert/README.md）。
import Foundation

/// 平面存放的 Float32 图像：`channel → 整幅平面`，支持 1 通道灰度与 3 通道 RGB。
public struct FloatImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let channels: Int
    /// 平面存放：`channel * (width * height) + y * width + x`。
    public let values: [Float]

    public init(width: Int, height: Int, channels: Int, values: [Float]) {
        precondition(width > 0 && height > 0, "图像尺寸必须为正")
        precondition(channels > 0, "通道数必须为正")
        precondition(values.count == width * height * channels, "values 数量必须等于 width × height × channels")
        self.width = width
        self.height = height
        self.channels = channels
        self.values = values
    }

    /// 读取一个像素分量；越界返回 nil。
    public func value(x: Int, y: Int, channel: Int) -> Float? {
        guard (0 ..< width).contains(x), (0 ..< height).contains(y), (0 ..< channels).contains(channel) else {
            return nil
        }
        return values[channel * (width * height) + y * width + x]
    }
}

/// 归一化采样网格：`columns × rows` 个源图坐标，行优先存放，坐标为 `[-1, 1]`。
public struct NormalizedSampleGrid: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    /// 行优先的 x 分量，数量 = `columns × rows`。
    public let xValues: [Float]
    /// 行优先的 y 分量，数量 = `columns × rows`。
    public let yValues: [Float]

    public init(columns: Int, rows: Int, xValues: [Float], yValues: [Float]) {
        precondition(columns > 0 && rows > 0, "网格行列数必须为正")
        precondition(
            xValues.count == columns * rows && yValues.count == columns * rows,
            "xValues / yValues 数量必须等于 columns × rows"
        )
        self.columns = columns
        self.rows = rows
        self.xValues = xValues
        self.yValues = yValues
    }

    /// 由逐点坐标构造（行优先）。
    public init(columns: Int, rows: Int, points: [(x: Float, y: Float)]) {
        self.init(
            columns: columns,
            rows: rows,
            xValues: points.map(\.x),
            yValues: points.map(\.y)
        )
    }

    /// 一个坐标点；越界返回 nil。
    public func point(column: Int, row: Int) -> (x: Float, y: Float)? {
        guard (0 ..< columns).contains(column), (0 ..< rows).contains(row) else { return nil }
        let index = row * columns + column
        return (xValues[index], yValues[index])
    }

    /// 恒等网格：每个点在源图上取自身位置（`align_corners=True` 约定），重采样结果即原图。
    public static func identity(columns: Int, rows: Int) -> NormalizedSampleGrid {
        let columns = max(columns, 1)
        let rows = max(rows, 1)
        var xValues = [Float]()
        var yValues = [Float]()
        xValues.reserveCapacity(columns * rows)
        yValues.reserveCapacity(columns * rows)
        for row in 0 ..< rows {
            let v = GridResampler.unit(row, count: rows)
            for column in 0 ..< columns {
                xValues.append(GridResampler.unit(column, count: columns) * 2 - 1)
                yValues.append(v * 2 - 1)
            }
        }
        return NormalizedSampleGrid(columns: columns, rows: rows, xValues: xValues, yValues: yValues)
    }
}

/// 网格重采样（Float32）。
public enum GridResampler {
    /// 把网格双线性插值到 `columns × rows`（`align_corners=True`）。
    public static func upsampleGrid(_ grid: NormalizedSampleGrid, columns: Int, rows: Int) -> NormalizedSampleGrid {
        let columns = max(columns, 1)
        let rows = max(rows, 1)
        var xValues = [Float]()
        var yValues = [Float]()
        xValues.reserveCapacity(columns * rows)
        yValues.reserveCapacity(columns * rows)
        for row in 0 ..< rows {
            let v = unit(row, count: rows)
            for column in 0 ..< columns {
                let point = interpolatedPoint(grid: grid, u: unit(column, count: columns), v: v)
                xValues.append(point.x)
                yValues.append(point.y)
            }
        }
        return NormalizedSampleGrid(columns: columns, rows: rows, xValues: xValues, yValues: yValues)
    }

    /// 按网格把源图重采样到目标尺寸；返回 Float32 图像（通道数与源图一致）。
    public static func resample(
        grid: NormalizedSampleGrid,
        source: FloatImage,
        targetWidth: Int,
        targetHeight: Int
    ) -> FloatImage {
        precondition(targetWidth > 0 && targetHeight > 0, "目标尺寸必须为正")
        let sourceWidth = source.width
        let sourceHeight = source.height
        let planeSize = sourceWidth * sourceHeight
        let targetPlaneSize = targetWidth * targetHeight
        let lastX = Float(sourceWidth - 1)
        let lastY = Float(sourceHeight - 1)
        var values = [Float](repeating: 0, count: targetPlaneSize * source.channels)

        for row in 0 ..< targetHeight {
            let v = unit(row, count: targetHeight)
            for column in 0 ..< targetWidth {
                let normalized = interpolatedPoint(grid: grid, u: unit(column, count: targetWidth), v: v)
                // 归一化 → 像素坐标（align_corners=True），越界 clamp。
                let sourceX = clamped((normalized.x + 1) * 0.5 * lastX, upper: lastX)
                let sourceY = clamped((normalized.y + 1) * 0.5 * lastY, upper: lastY)
                let x0 = Int(sourceX.rounded(.down))
                let y0 = Int(sourceY.rounded(.down))
                let x1 = min(x0 + 1, sourceWidth - 1)
                let y1 = min(y0 + 1, sourceHeight - 1)
                let fractionX = sourceX - Float(x0)
                let fractionY = sourceY - Float(y0)
                for channel in 0 ..< source.channels {
                    let base = channel * planeSize
                    let topLeft = source.values[base + y0 * sourceWidth + x0]
                    let topRight = source.values[base + y0 * sourceWidth + x1]
                    let bottomLeft = source.values[base + y1 * sourceWidth + x0]
                    let bottomRight = source.values[base + y1 * sourceWidth + x1]
                    let top = topLeft + (topRight - topLeft) * fractionX
                    let bottom = bottomLeft + (bottomRight - bottomLeft) * fractionX
                    values[channel * targetPlaneSize + row * targetWidth + column] =
                        top + (bottom - top) * fractionY
                }
            }
        }
        return FloatImage(width: targetWidth, height: targetHeight, channels: source.channels, values: values)
    }

    /// 便捷入口：在源图自身分辨率上去畸变（上游 `demo.py` 的契约）。
    public static func resample(grid: NormalizedSampleGrid, source: FloatImage) -> FloatImage {
        resample(grid: grid, source: source, targetWidth: source.width, targetHeight: source.height)
    }

    /// `align_corners=True` 下第 `index` 个采样点在 `[0, 1]` 上的位置；只有一个点时取 0。
    static func unit(_ index: Int, count: Int) -> Float {
        count > 1 ? Float(index) / Float(count - 1) : 0
    }

    /// 网格在 `(u, v) ∈ [0, 1]` 处的双线性插值坐标（`align_corners=True`）。
    static func interpolatedPoint(grid: NormalizedSampleGrid, u: Float, v: Float) -> (x: Float, y: Float) {
        let gridX = clamped(u, upper: 1) * Float(grid.columns - 1)
        let gridY = clamped(v, upper: 1) * Float(grid.rows - 1)
        let column0 = Int(gridX.rounded(.down))
        let row0 = Int(gridY.rounded(.down))
        let column1 = min(column0 + 1, grid.columns - 1)
        let row1 = min(row0 + 1, grid.rows - 1)
        let fractionX = gridX - Float(column0)
        let fractionY = gridY - Float(row0)

        func interpolate(_ values: [Float]) -> Float {
            let topLeft = values[row0 * grid.columns + column0]
            let topRight = values[row0 * grid.columns + column1]
            let bottomLeft = values[row1 * grid.columns + column0]
            let bottomRight = values[row1 * grid.columns + column1]
            let top = topLeft + (topRight - topLeft) * fractionX
            let bottom = bottomLeft + (bottomRight - bottomLeft) * fractionX
            return top + (bottom - top) * fractionY
        }

        return (sanitized(interpolate(grid.xValues)), sanitized(interpolate(grid.yValues)))
    }

    /// 非有限坐标（NaN / ±∞）视为归一化 0（图像中心）：不让坏网格值传播成坏像素。
    static func sanitized(_ value: Float) -> Float {
        value.isFinite ? value : 0
    }

    /// 非有限值视为 0；其余钳制到 `[0, upper]`。
    static func clamped(_ value: Float, upper: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), max(upper, 0))
    }
}
