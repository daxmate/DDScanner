// PaperEnhancer —— 纸张增强（去折痕 / 提白 / 换纸色）的语义测试（本机 `swift test` 可跑，无模拟器）。
//
// 守的语义（批 25 任务包交付 C）：
//   ① 关闭 = 逐字节 no-op；非 3 通道 = no-op；
//   ② 合成折痕斜坡：**亮侧与暗侧一起被抹平**（这正是否定「纯阈值刷白」方案的锚 ——
//      纯阈值只动亮侧，暗侧原样保留）；
//   ③ 合成平坦页 + 亮度斜坡：背景列均值 std 下降 ≥ 一个量级（阴影被抹平）；
//   ④ 纸色：中性纸面输出 ≈ 目标色（ΔE ≤ 2）；
//   ⑤ 浅色内容在 255 档保留；
//   ⑥ 文字对比度不下降；
//   ⑦ 退化（全黑 / 全白 / 1×1 / 1×N / 非有限值 / 超大 whiteness）不崩、行为明确；
//   ⑧ 确定性（两次调用逐字节相同）；
//   ⑨ 核宽按图宽自适应（3.78%，2669px → 101 —— 与参考实现同档）。
import Foundation
import Testing
@testable import DDScannerCore

@Suite("PaperEnhancer")
struct PaperEnhancerTests {
    // MARK: - 夹具

    private func make(
        width: Int,
        height: Int,
        channels: Int = 3,
        _ pixel: (Int, Int) -> (Float, Float, Float)
    ) -> FloatImage {
        let planeSize = width * height
        var values = [Float](repeating: 0, count: planeSize * channels)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let (red, green, blue) = pixel(x, y)
                let index = y * width + x
                values[index] = red
                if channels >= 3 {
                    values[planeSize + index] = green
                    values[2 * planeSize + index] = blue
                }
            }
        }
        return FloatImage(width: width, height: height, channels: channels, values: values)
    }

    private func channel(_ image: FloatImage, _ index: Int, _ x: Int, _ y: Int) -> Float {
        image.values[index * image.width * image.height + y * image.width + x]
    }

    /// 灰度图（R=G=B=value）。
    private func gray(width: Int, height: Int, _ value: (Int, Int) -> Float) -> FloatImage {
        make(width: width, height: height) { x, y in
            let v = value(x, y)
            return (v, v, v)
        }
    }

    /// 某通道「列均值」序列（用于量测 1-D 背景变化）。
    private func columnMeans(_ image: FloatImage, channel index: Int = 0) -> [Double] {
        (0 ..< image.width).map { x in
            var total = 0.0
            for y in 0 ..< image.height { total += Double(channel(image, index, x, y)) }
            return total / Double(image.height)
        }
    }

    private func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot()
    }

    /// 灰度斜坡中段外沿的中位数（当作「纸面基准」）。
    private func paperLevel(_ image: FloatImage, channel index: Int = 0) -> Double {
        let width = image.width
        let mid = image.height / 2
        var samples = [Float]()
        for x in 0 ..< width where x < width / 5 || x >= width - width / 5 {
            samples.append(channel(image, index, x, mid))
        }
        samples.sort()
        return Double(samples[samples.count / 2])
    }

    /// 中段（中央 1/2 列）扫描线的极值。
    private func extremities(_ image: FloatImage) -> (minimum: Double, maximum: Double) {
        let mid = image.height / 2
        var minimum = Double.greatestFiniteMagnitude
        var maximum = -Double.greatestFiniteMagnitude
        for x in (image.width / 4) ..< (image.width * 3 / 4) {
            let v = Double(channel(image, 0, x, mid))
            minimum = min(minimum, v)
            maximum = max(maximum, v)
        }
        return (minimum, maximum)
    }

    private func lab(_ red: Double, _ green: Double, _ blue: Double) -> (Double, Double, Double) {
        func toLinear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let r = toLinear(red)
        let g = toLinear(green)
        let b = toLinear(blue)
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        let epsilon = 216.0 / 24389.0
        let kappa = 24389.0 / 27.0
        func f(_ t: Double) -> Double { t > epsilon ? cbrt(t) : (kappa * t + 16) / 116 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    private func deltaE(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let da = lab(a.0, a.1, a.2)
        let db = lab(b.0, b.1, b.2)
        return ((da.0 - db.0) * (da.0 - db.0) + (da.1 - db.1) * (da.1 - db.1)
            + (da.2 - db.2) * (da.2 - db.2)).squareRoot()
    }

    /// 合成「折痕」页：中性纸面 + 一条**宽折痕**（暗侧阴影 + 亮侧受光）。
    /// 折痕宽 ≈ 5% 图宽（σ），**远宽于**核半径（核宽 3.78%，半径≈1.9% 图宽）——
    /// 这正是参考实现里折痕被抹平的工作区间：底色 `bg` 跟着折痕走，单增益把它拉回纸面水平。
    /// （反面提醒：比核**窄**的暗点是另一回事 —— 那时 `bg` 被闭运算直接填平，增益≈ 1，
    ///  折痕反而不动；所以夹具必须落在宽折痕区间，否则用例测不到真正的机制。）
    private func creaseFixture(width: Int = 600, height: Int = 200) -> FloatImage {
        let paper: Float = 0.82
        let darkCenter = 0.35 * Double(width)
        let brightCenter = 0.65 * Double(width)
        let sigma = 0.05 * Double(width)
        return gray(width: width, height: height) { x, _ in
            let dark = 0.26 * exp(-pow((Double(x) - darkCenter) / sigma, 2) / 2)
            let bright = 0.13 * exp(-pow((Double(x) - brightCenter) / sigma, 2) / 2)
            return Float(min(max(Double(paper) - dark + bright, 0), 1))
        }
    }

    // MARK: - ① 关闭 = no-op

    @Test("关闭（options = nil）逐字节 no-op")
    func disabledOptionsAreByteIdentical() {
        let source = creaseFixture()
        let output = PaperEnhancer.enhance(source, options: nil)
        #expect(output.values == source.values)
        #expect(output == source)
    }

    @Test("非 3 通道图原样返回（不崩、不改数值）")
    func nonRGBImageIsUnchanged() {
        let source = FloatImage(width: 4, height: 3, channels: 1, values: (0 ..< 12).map { Float($0) / 12 })
        let output = PaperEnhancer.enhance(source, options: .conservative)
        #expect(output == source)
    }

    // MARK: - ② 折痕：亮侧 + 暗侧一起抹平

    @Test("合成折痕：亮侧与暗侧一起被抹平（否定纯阈值方案）")
    func creaseBothSidesAreFlattened() {
        let source = creaseFixture()
        let output = PaperEnhancer.enhance(source, options: .conservative)

        let inputLevel = paperLevel(source)
        let inputExtremes = extremities(source)
        let inputDarkGap = inputLevel - inputExtremes.minimum
        let inputBrightGap = inputExtremes.maximum - inputLevel
        // 夹具自证：折痕确实存在（否则用例恒真 = 假绿）。
        #expect(inputDarkGap > 0.15)
        #expect(inputBrightGap > 0.05)

        let outputLevel = paperLevel(output)
        let outputExtremes = extremities(output)
        let outputDarkGap = outputLevel - outputExtremes.minimum
        let outputBrightGap = outputExtremes.maximum - outputLevel
        // 暗侧（纯阈值方案保留的那一侧）必须也被抹平。
        #expect(outputDarkGap * 255 < 3)
        #expect(outputBrightGap * 255 < 3)
    }

    // MARK: - ③ 平坦页：背景被压平

    @Test("合成平坦页 + 亮度斜坡：背景列均值 std 下降 ≥ 一个量级")
    func flatPageBackgroundIsFlattened() {
        let width = 400
        let source = gray(width: width, height: 120) { x, _ in
            Float(0.55 + 0.35 * Double(x) / Double(width))
        }
        let inputStd = standardDeviation(columnMeans(source))
        #expect(inputStd > 0.05)

        let output = PaperEnhancer.enhance(source, options: .conservative)
        let outputStd = standardDeviation(columnMeans(output))
        #expect(outputStd * 10 < inputStd)
    }

    // MARK: - ④ 纸色

    @Test("纸色：中性纸面输出 ≈ 目标色（ΔE ≤ 2）")
    func paperColorMatchesTarget() {
        // 中性纸面（R=G=B）+ 轻微颗粒，避免「恒定图」让用例退化。
        let source = gray(width: 120, height: 120) { x, y in
            Float(0.78 + 0.02 * Double((x * 7 + y * 13) % 5) / 5)
        }
        for preset in PaperColorPreset.allCases {
            let color = preset.paperColor
            let output = PaperEnhancer.enhance(
                source, options: PaperEnhanceOptions(whiteness: 255, paperColor: color)
            )
            // 取中心区域均值（避开边界）。
            var sums = (0.0, 0.0, 0.0)
            var count = 0.0
            for y in 20 ..< 100 {
                for x in 20 ..< 100 {
                    sums.0 += Double(channel(output, 0, x, y))
                    sums.1 += Double(channel(output, 1, x, y))
                    sums.2 += Double(channel(output, 2, x, y))
                    count += 1
                }
            }
            let measured = (sums.0 / count, sums.1 / count, sums.2 / count)
            let target = (
                Double(color.red) / 255, Double(color.green) / 255, Double(color.blue) / 255
            )
            #expect(deltaE(measured, target) <= 2)
        }
    }

    // MARK: - ⑤ 浅色内容 + ⑥ 文字对比度

    @Test("浅灰细线在 255 档仍存在（310 档更弱）")
    func lightContentSurvivesAtConservativeWhiteness() {
        let width = 400
        let lineValue: Float = 0.90
        let source = gray(width: width, height: 100) { x, _ in
            (x % 40) < 2 ? lineValue : 0.95
        }
        let inputDip = 0.95 - Double(lineValue)
        #expect(inputDip > 0.03)

        func dip(_ image: FloatImage) -> Double {
            let mid = image.height / 2
            var minimum = 1.0
            for x in 100 ..< 300 { minimum = min(minimum, Double(channel(image, 0, x, mid))) }
            var paper = 0.0
            for x in 100 ..< 300 where (x % 40) >= 6 { paper = max(paper, Double(channel(image, 0, x, mid))) }
            return paper - minimum
        }

        let conservative = PaperEnhancer.enhance(source, options: .conservative)
        #expect(dip(conservative) * 255 > 5)
        let maximum = PaperEnhancer.enhance(source, options: .maximum)
        #expect(dip(maximum) <= dip(conservative) + 1e-6)
    }

    @Test("文字对比度不下降（合成黑白文字）")
    func textContrastDoesNotDrop() {
        let width = 400
        let source = gray(width: width, height: 100) { x, _ in
            // 每 40 列一段：中间 12 列是墨（黑），其余是纸（白）。
            (x % 40) >= 14 && (x % 40) < 26 ? 0.06 : 0.92
        }
        func contrast(_ image: FloatImage) -> Double {
            let mid = image.height / 2
            var paper = 0.0
            var ink = 1.0
            for x in 100 ..< 300 {
                let v = Double(channel(image, 0, x, mid))
                if (x % 40) >= 14 && (x % 40) < 26 { ink = min(ink, v) } else { paper = max(paper, v) }
            }
            return paper - ink
        }
        let inputContrast = contrast(source)
        #expect(inputContrast > 0.5)
        let output = PaperEnhancer.enhance(source, options: .conservative)
        #expect(contrast(output) >= inputContrast)
    }

    // MARK: - ⑦ 退化

    @Test("退化输入：全黑 / 全白 / 1×1 / 1×N / 非有限值 / 超大 whiteness 不崩且行为明确")
    func degenerateInputsAreDefined() {
        // 全黑 → 输出仍为全黑（纸面参考为 0，增益收敛为 0）。
        let black = gray(width: 8, height: 8) { _, _ in 0 }
        let blackOutput = PaperEnhancer.enhance(black, options: .conservative)
        #expect(blackOutput.values.allSatisfy { $0 == 0 })

        // 全白 → 输出仍为全白。
        let white = gray(width: 8, height: 8) { _, _ in 1 }
        let whiteOutput = PaperEnhancer.enhance(white, options: .conservative)
        #expect(whiteOutput.values.allSatisfy { abs($0 - 1) < 1e-6 })

        // 1×1 / 1×N / N×1：不崩、尺寸不变、数值有限。
        for (width, height) in [(1, 1), (1, 64), (64, 1)] {
            let source = gray(width: width, height: height) { _, _ in 0.8 }
            let output = PaperEnhancer.enhance(source, options: .conservative)
            #expect(output.width == width)
            #expect(output.height == height)
            #expect(output.values.allSatisfy { $0.isFinite })
        }

        // 非有限值 → 输出全有限（NaN / ±∞ 按 0 参与）。
        var values = [Float](repeating: 0.8, count: 3 * 16 * 16)
        values[5] = .nan
        values[100] = .infinity
        values[200] = -.infinity
        let poisoned = FloatImage(width: 16, height: 16, channels: 3, values: values)
        let poisonedOutput = PaperEnhancer.enhance(poisoned, options: .conservative)
        #expect(poisonedOutput.values.allSatisfy { $0.isFinite })

        // 超大 / 负 whiteness → 钳制到 [0, 310]，不崩且与钳制档逐字节相同。
        let source = creaseFixture(width: 200, height: 80)
        let huge = PaperEnhancer.enhance(source, options: PaperEnhanceOptions(whiteness: 9_999))
        let capped = PaperEnhancer.enhance(source, options: PaperEnhanceOptions(whiteness: 310))
        #expect(huge.values == capped.values)
        let negative = PaperEnhancer.enhance(source, options: PaperEnhanceOptions(whiteness: -50))
        #expect(negative.values.allSatisfy { $0.isFinite })
    }

    // MARK: - ⑧ 确定性

    @Test("确定性：同输入两次调用逐字节相同")
    func enhancementIsDeterministic() {
        let source = creaseFixture()
        let first = PaperEnhancer.enhance(source, options: PaperEnhanceOptions(whiteness: 255, paperColor: .cream))
        let second = PaperEnhancer.enhance(source, options: PaperEnhanceOptions(whiteness: 255, paperColor: .cream))
        #expect(first.values == second.values)
    }

    // MARK: - ⑨ 核宽自适应（口径钉死）

    @Test("核宽按图宽自适应：3.78%，2669px → 101（与参考实现同档）")
    func kernelSizeIsAdaptive() {
        #expect(PaperEnhancer.kernelSize(forWidth: 2669, height: 3843) == 101)
        #expect(PaperEnhancer.kernelSize(forWidth: 1000, height: 1000) == 39)
        // 小图不得小于 1、不得超过短边，且恒为奇数。
        for width in [1, 2, 3, 5, 40, 999] {
            let kernel = PaperEnhancer.kernelSize(forWidth: width, height: width)
            #expect(kernel >= 1)
            #expect(kernel <= max(min(width, width), 1))
            #expect(kernel % 2 == 1)
        }
    }

    @Test("椭圆核逐行半宽与参考实现（cv2）同公式")
    func ellipseRowWidthsMatchReference() {
        // K=9 的 cv2 实测： [0,3,3,4,4,4,3,3,0]
        #expect(LinearMorphology.rowHalfWidths(kernel: 9) == [0, 3, 3, 4, 4, 4, 3, 3, 0])
        // K=5： [0,2,2,2,0]
        #expect(LinearMorphology.rowHalfWidths(kernel: 5) == [0, 2, 2, 2, 0])
        #expect(LinearMorphology.rowHalfWidths(kernel: 1) == [0])
        // K=101：中心行半宽 = 50，两端为 0。
        let widths = LinearMorphology.rowHalfWidths(kernel: 101)
        #expect(widths.count == 101)
        #expect(widths[50] == 50)
        #expect(widths[0] == 0)
        #expect(widths[100] == 0)
    }

    @Test("形态学闭：常数场不变；单点亮斑被闭运算填平（膨胀→腐蚀语义）")
    func morphologySemantics() {
        let constant = [Float](repeating: 0.5, count: 20 * 10)
        let closed = LinearMorphology.close(constant, width: 20, height: 10, kernel: 5)
        #expect(closed == constant)

        // 中心一个暗点（远小于核）→ 闭运算把它填平（值升到周围水平）。
        var withDarkSpot = constant
        withDarkSpot[5 * 20 + 10] = 0.1
        let filled = LinearMorphology.close(withDarkSpot, width: 20, height: 10, kernel: 5)
        #expect(filled[5 * 20 + 10] > 0.4)
        // 闭运算是**扩展性**操作：结果逐点 ≥ 输入。
        for index in withDarkSpot.indices {
            #expect(filled[index] >= withDarkSpot[index] - 1e-6)
        }
        // 除暗点被填平外，其余像素逐个保持原值。
        #expect(filled.filter { $0 != 0.5 }.isEmpty)
    }
}
