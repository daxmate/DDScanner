// AcceleratedGridResampler —— `GridResampler.resample` 的向量化实现（Accelerate / vDSP，Float32）。
//
// 语义与标量实现逐点一致：网格双线性插值（align_corners=True）→ 归一化坐标转像素坐标
// （越界 clamp、非有限值按归一化 0）→ 双线性采样；通道独立、越界 clamp（不零填充）。
// 标量实现已移到测试侧作**参考实现**（见 docs/contract-register.md「参考实现」），
// 产品路径只有本文件这一份；等价性由 `GridResampleEquivalenceTests` 守着（max abs diff ≤ 1e-3）。
//
// 向量化要点：
//   ① 网格插值：u 只依赖输出列、v 只依赖输出行 → 列索引向量只算一次；
//      每行用 `vDSP_vlint`（表 + 线性插值）替代逐像素 4 次网格采集，再纵向混合。
//   ② 坐标换算与索引构造：全部走 vDSP 逐元素算子（vclip / vsadd / vsmul / vsub / vma / vsmsa）。
//   ③ 源图双线性采样：`vDSP_vindex` 一次采集一整行（4 次/通道/行），再做两次线性混合。
//
// 精度守卫：索引由 Float32 承载（`vDSP_vindex` 的索引类型），故要求源平面像素数可被 Float32
// 精确表示（≤ 2^24）。App 读入路径最长边限 4032px（≤ 4032×4032 = 16.26M < 16.78M），恒满足；
// 更大平面需要改用 `vDSP_vgathr`（UInt 索引）。
import Accelerate
import Foundation

enum AcceleratedGridResampler {
    static func resample(
        grid: NormalizedSampleGrid,
        source: FloatImage,
        targetWidth: Int,
        targetHeight: Int
    ) -> FloatImage {
        let gridColumns = grid.columns
        let gridRows = grid.rows
        let sourceWidth = source.width
        let sourceHeight = source.height
        let channelCount = source.channels
        let sourcePlaneSize = sourceWidth * sourceHeight
        let targetPlaneSize = targetWidth * targetHeight
        let lastSourceX = Float(sourceWidth - 1)
        let lastSourceY = Float(sourceHeight - 1)

        precondition(
            sourcePlaneSize <= (1 << 24),
            "向量化重采样要求源平面像素数 ≤ 2^24（Float32 精确索引），实际 \(sourcePlaneSize)"
        )

        // ── 只算一次的位置表 ──────────────────────────────────────────────
        // 列方向：u 只依赖输出列（行方向 v 依赖输出行，逐行算标量即可）。
        var columnTicks = [Float](repeating: 0, count: targetWidth)
        for column in 0 ..< targetWidth {
            let u = GridResampler.clamped(GridResampler.unit(column, count: targetWidth), upper: 1)
            columnTicks[column] = u * Float(gridColumns - 1)
        }
        // 网格行尾补 2 个冗余值：`vDSP_vlint` 会读 A[trunc(B)+1]，末列时 trunc(B) == cols-1。
        let paddedStride = gridColumns + 2
        var paddedX = [Float](repeating: 0, count: gridRows * paddedStride)
        var paddedY = [Float](repeating: 0, count: gridRows * paddedStride)
        for row in 0 ..< gridRows {
            let base = row * paddedStride
            let last = gridColumns - 1
            for column in 0 ..< gridColumns {
                paddedX[base + column] = grid.xValues[row * gridColumns + column]
                paddedY[base + column] = grid.yValues[row * gridColumns + column]
            }
            paddedX[base + last + 1] = paddedX[base + last]
            paddedX[base + last + 2] = paddedX[base + last]
            paddedY[base + last + 1] = paddedY[base + last]
            paddedY[base + last + 2] = paddedY[base + last]
        }

        // 网格含 NaN/±∞ 时，标量语义是「插值结果按 0 处理」；正常网格跳过逐行修正（快路径）。
        let gridIsFinite = grid.xValues.allSatisfy(\.isFinite) && grid.yValues.allSatisfy(\.isFinite)

        // ── 每行中间结果（长度 = 输出宽），循环内复用 ─────────────────────
        let width = targetWidth
        let gridTop = scratch(width)
        let gridBottom = scratch(width)
        let coordinate = scratch(width)
        let lowerX = scratch(width)
        let upperX = scratch(width)
        let fractionX = scratch(width)
        let lowerY = scratch(width)
        let upperY = scratch(width)
        let fractionY = scratch(width)
        let rowBase0 = scratch(width)
        let rowBase1 = scratch(width)
        let indexTL = scratch(width)
        let indexTR = scratch(width)
        let indexBL = scratch(width)
        let indexBR = scratch(width)
        let sampleTL = scratch(width)
        let sampleTR = scratch(width)
        let sampleBL = scratch(width)
        let sampleBR = scratch(width)
        let delta = scratch(width)
        let blended = scratch(width)
        let verticalFractionVector = scratch(width)
        defer {
            for buffer in [
                gridTop, gridBottom, coordinate, lowerX, upperX, fractionX,
                lowerY, upperY, fractionY, rowBase0, rowBase1,
                indexTL, indexTR, indexBL, indexBR,
                sampleTL, sampleTR, sampleBL, sampleBR, delta, blended, verticalFractionVector,
            ] {
                buffer.deallocate()
            }
        }

        let count = vDSP_Length(width)
        var intCount = Int32(width)
        var zero: Float = 0
        let scaleX = lastSourceX
        let scaleY = lastSourceY
        var rowStride = Float(sourceWidth)
        var values = [Float](repeating: 0, count: targetPlaneSize * channelCount)

        paddedX.withUnsafeBufferPointer { paddedXPointer in
            paddedY.withUnsafeBufferPointer { paddedYPointer in
                source.values.withUnsafeBufferPointer { sourcePointer in
                    values.withUnsafeMutableBufferPointer { outputPointer in
                        for row in 0 ..< targetHeight {
                            let v = GridResampler.clamped(
                                GridResampler.unit(row, count: targetHeight),
                                upper: 1
                            )
                            let gridY = v * Float(gridRows - 1)
                            let gridRow0 = Int(gridY.rounded(.down))
                            let gridRow1 = min(gridRow0 + 1, gridRows - 1)
                            let verticalFraction = gridY - Float(gridRow0)
                            var verticalFractionValue = verticalFraction
                            vDSP_vfill(
                                &verticalFractionValue, verticalFractionVector.baseAddress!, 1, count
                            )

                            // ① X：网格插值 → 像素坐标（clamp）→ 下界/上界索引 + 小数权重
                            interpolateGridComponent(
                                padded: paddedXPointer.baseAddress!,
                                stride: paddedStride,
                                row0: gridRow0,
                                row1: gridRow1,
                                verticalFraction: verticalFractionVector.baseAddress!,
                                ticks: columnTicks,
                                top: gridTop,
                                bottom: gridBottom,
                                out: coordinate.baseAddress!,
                                count: count
                            )
                            if !gridIsFinite { sanitizeNonFinite(coordinate) }
                            toPixelCoordinate(
                                input: coordinate.baseAddress!,
                                scale: scaleX,
                                upperBound: scaleX,
                                lower: lowerX,
                                upper: upperX,
                                fraction: fractionX,
                                zero: &zero,
                                intCount: &intCount,
                                count: count
                            )

                            // ② Y：同上
                            interpolateGridComponent(
                                padded: paddedYPointer.baseAddress!,
                                stride: paddedStride,
                                row0: gridRow0,
                                row1: gridRow1,
                                verticalFraction: verticalFractionVector.baseAddress!,
                                ticks: columnTicks,
                                top: gridTop,
                                bottom: gridBottom,
                                out: coordinate.baseAddress!,
                                count: count
                            )
                            if !gridIsFinite { sanitizeNonFinite(coordinate) }
                            toPixelCoordinate(
                                input: coordinate.baseAddress!,
                                scale: scaleY,
                                upperBound: scaleY,
                                lower: lowerY,
                                upper: upperY,
                                fraction: fractionY,
                                zero: &zero,
                                intCount: &intCount,
                                count: count
                            )

                            // ③ 四个采集索引：idx = y · 源宽 + x（< 平面像素数，Float32 精确）
                            vDSP_vsmul(lowerY.baseAddress!, 1, &rowStride, rowBase0.baseAddress!, 1, count)
                            vDSP_vsmul(upperY.baseAddress!, 1, &rowStride, rowBase1.baseAddress!, 1, count)
                            vDSP_vadd(rowBase0.baseAddress!, 1, lowerX.baseAddress!, 1, indexTL.baseAddress!, 1, count)
                            vDSP_vadd(rowBase0.baseAddress!, 1, upperX.baseAddress!, 1, indexTR.baseAddress!, 1, count)
                            vDSP_vadd(rowBase1.baseAddress!, 1, lowerX.baseAddress!, 1, indexBL.baseAddress!, 1, count)
                            vDSP_vadd(rowBase1.baseAddress!, 1, upperX.baseAddress!, 1, indexBR.baseAddress!, 1, count)

                            // ④ 逐通道双线性采样
                            for channel in 0 ..< channelCount {
                                let plane = sourcePointer.baseAddress! + channel * sourcePlaneSize
                                vDSP_vindex(plane, indexTL.baseAddress!, 1, sampleTL.baseAddress!, 1, count)
                                vDSP_vindex(plane, indexTR.baseAddress!, 1, sampleTR.baseAddress!, 1, count)
                                vDSP_vindex(plane, indexBL.baseAddress!, 1, sampleBL.baseAddress!, 1, count)
                                vDSP_vindex(plane, indexBR.baseAddress!, 1, sampleBR.baseAddress!, 1, count)

                                // 横向混合（权重是向量）：混合 = TL + fx·(TR-TL)
                                // 注意 vDSP_vsub 的参数顺序是 (B, A) → C = A - B。
                                vDSP_vsub(
                                    sampleTL.baseAddress!, 1, sampleTR.baseAddress!, 1,
                                    delta.baseAddress!, 1, count
                                )
                                vDSP_vma(
                                    delta.baseAddress!, 1, fractionX.baseAddress!, 1,
                                    sampleTL.baseAddress!, 1, blended.baseAddress!, 1, count
                                )
                                vDSP_vsub(
                                    sampleBL.baseAddress!, 1, sampleBR.baseAddress!, 1,
                                    delta.baseAddress!, 1, count
                                )
                                vDSP_vma(
                                    delta.baseAddress!, 1, fractionX.baseAddress!, 1,
                                    sampleBL.baseAddress!, 1, gridTop.baseAddress!, 1, count
                                )
                                // 纵向混合（权重是 Y 轴像素小数）：out = top + fy·(bottom-top)
                                vDSP_vsub(
                                    blended.baseAddress!, 1, gridTop.baseAddress!, 1,
                                    delta.baseAddress!, 1, count
                                )
                                vDSP_vma(
                                    delta.baseAddress!, 1, fractionY.baseAddress!, 1,
                                    blended.baseAddress!, 1,
                                    outputPointer.baseAddress! + channel * targetPlaneSize + row * width,
                                    1, count
                                )
                            }
                        }
                    }
                }
            }
        }

        return FloatImage(width: targetWidth, height: targetHeight, channels: channelCount, values: values)
    }

    // MARK: - 行内步骤

    /// 网格某分量的整行插值：两行横向表插值（`vDSP_vlint`）后按行分数纵向混合。
    private static func interpolateGridComponent(
        padded: UnsafePointer<Float>,
        stride: Int,
        row0: Int,
        row1: Int,
        verticalFraction: UnsafePointer<Float>,
        ticks: [Float],
        top: UnsafeMutableBufferPointer<Float>,
        bottom: UnsafeMutableBufferPointer<Float>,
        out: UnsafeMutablePointer<Float>,
        count: vDSP_Length
    ) {
        let nominal = vDSP_Length(stride)
        vDSP_vlint(padded + row0 * stride, ticks, 1, top.baseAddress!, 1, count, nominal)
        vDSP_vlint(padded + row1 * stride, ticks, 1, bottom.baseAddress!, 1, count, nominal)
        // out = bottom - top（vDSP_vsub 的参数顺序是 (B, A) → C = A - B）
        vDSP_vsub(top.baseAddress!, 1, bottom.baseAddress!, 1, out, 1, count)
        // out = top + fy·(bottom - top)
        vDSP_vma(out, 1, verticalFraction, 1, top.baseAddress!, 1, out, 1, count)
    }

    /// 归一化坐标 → 像素坐标：`clamped((value + 1) · 0.5 · last, upper: last)`，
    /// 再拆出下取整索引、上界钳制的下一个索引与小数权重（取整顺序与标量实现一致）。
    private static func toPixelCoordinate(
        input: UnsafeMutablePointer<Float>,
        scale: Float,
        upperBound: Float,
        lower: UnsafeMutableBufferPointer<Float>,
        upper: UnsafeMutableBufferPointer<Float>,
        fraction: UnsafeMutableBufferPointer<Float>,
        zero: inout Float,
        intCount: inout Int32,
        count: vDSP_Length
    ) {
        var one: Float = 1
        var half: Float = 0.5
        var scaleValue = scale
        var bound = upperBound
        vDSP_vsadd(input, 1, &one, input, 1, count)
        vDSP_vsmul(input, 1, &half, input, 1, count)
        vDSP_vsmul(input, 1, &scaleValue, input, 1, count)
        vDSP_vclip(input, 1, &zero, &bound, input, 1, count)
        vvfloorf(lower.baseAddress!, input, &intCount)
        vDSP_vsub(lower.baseAddress!, 1, input, 1, fraction.baseAddress!, 1, count)
        vDSP_vsadd(lower.baseAddress!, 1, &one, upper.baseAddress!, 1, count)
        vDSP_vclip(upper.baseAddress!, 1, &zero, &bound, upper.baseAddress!, 1, count)
    }

    /// 非有限值按 0 处理（只在网格本身含 NaN/±∞ 时逐行调用）。
    private static func sanitizeNonFinite(_ buffer: UnsafeMutableBufferPointer<Float>) {
        for index in buffer.indices where !buffer[index].isFinite {
            buffer[index] = 0
        }
    }

    private static func scratch(_ count: Int) -> UnsafeMutableBufferPointer<Float> {
        UnsafeMutableBufferPointer<Float>.allocate(capacity: count)
    }
}
