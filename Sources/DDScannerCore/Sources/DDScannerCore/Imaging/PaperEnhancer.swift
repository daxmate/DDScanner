// PaperEnhancer —— 纸张增强：去折痕 / 提白 / 换纸色（批 25）。
//
// 口径 = 批 23/24 spike 里唯一实测通过的「B」方案（参考实现 `/tmp/ddscanner-spike7/render.py`
// 与 `/tmp/ddscanner-spike6/crease2.py`，本文件逐字移植其数学）：
//   ① 转到**线性域**，取亮度（`gray_enc = 0.299R + 0.587G + 0.114B`，**编码域**加权，
//      再 `srgb→linear`；与参考实现同序同精度）；
//   ② **大核形态学闭**（椭圆核，核宽 = 图宽 × 3.78%，本图 2669px → 101）在**线性域**估计纸面底色
//      `bg`——闭运算把暗侧折痕、字缝都填平，得到「没有折痕的纸面亮度」；
//   ③ 纸面参考 = `bg` 的 **92 分位** `p`；再取 `bg ≥ p80` 的像素当作纸面，
//      其 `gray_lin` 中位数 = `paper_ref`（源图纸面亮度中位数，本图编码 ≈190）；
//   ④ **亮度单增益**（**不是逐通道**——批 23 已证逐通道白平衡会黄偏 ΔE 17.9）：
//      `gain = (p / max(bg, ε)) · (target / paper_ref)`，`out_lin = clip(img_lin · gain)`；
//   ⑤ 再叠**纸色**（乘性着色：纸底视为 1.0，整体乘目标色，逐字节不产生彩边）；
//   ⑥ 回编码域。
//
// 白度锚点（对外语义，写死）：`whiteness` = **纸面亮度的目标值，编码域 0–255**。
//   - 源图纸面亮度中位数（编码 ≈190）↔ **255 档**：折痕亮暗两侧一起抹平、纸面灰纹理保留；
//   - **310 档** = PS 色阶拉满那种「死白」：浅灰纹理断崖消失（实测 30.7 → 0.00）；
//   - 默认 **255**；允许 `[0, 310]`，超出钳制。
//
// **默认安全**：`options == nil`（或非 3 通道）→ **逐字节 no-op**，不重采样、不改数值。
//
// 性能：全分辨率 10.26 MP（2669×3843）在 Mac 上实测见批 25 报告；形态学是主成本
// （`LinearMorphology`，与 cv2 同算法的 O(核行数 × 像素数)）。分层只依赖
// Foundation / CoreGraphics / Accelerate（`check-forbidden-imports.sh` 守着）。
import Accelerate
import CoreGraphics
import Foundation

// MARK: - 纸色

/// 目标纸底颜色（编码域 0–255）。
public struct PaperColor: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// 纯白（默认）。
    public static let white = PaperColor(red: 255, green: 255, blue: 255)
    /// 米白。
    public static let cream = PaperColor(red: 255, green: 252, blue: 242)
    /// 暖黄。
    public static let warmYellow = PaperColor(red: 252, green: 247, blue: 230)
}

/// 内置纸色预设（大象拍板：几种纸色都放进去，默认白色，用户在设置里选）。
public enum PaperColorPreset: String, CaseIterable, Sendable {
    case white
    case cream
    case warmYellow

    public var paperColor: PaperColor {
        switch self {
        case .white: return .white
        case .cream: return .cream
        case .warmYellow: return .warmYellow
        }
    }

    /// 展示名（App 可直接用；本地化由 App 层决定，Core 不引资源）。
    public var displayName: String {
        switch self {
        case .white: return "白"
        case .cream: return "米白"
        case .warmYellow: return "暖黄"
        }
    }
}

// MARK: - 选项

/// 纸张增强选项。`nil`（不传选项）= 关闭 = 原图预设。
public struct PaperEnhanceOptions: Equatable, Sendable {
    /// 默认白度档（保守档：折痕全消、纸面灰纹理保留）。
    public static let defaultWhiteness: Double = 255
    /// 最高白度档（PS 那种死白；浅灰纹理断崖消失）。
    public static let maximumWhiteness: Double = 310

    /// 纸面亮度目标（编码域 0–255）；超出 `[0, maximumWhiteness]` 会被钳制。
    public var whiteness: Double
    /// 目标纸色（默认白）。
    public var paperColor: PaperColor

    public init(
        whiteness: Double = PaperEnhanceOptions.defaultWhiteness,
        paperColor: PaperColor = .white
    ) {
        self.whiteness = whiteness
        self.paperColor = paperColor
    }

    /// 保守档（255）。
    public static let conservative = PaperEnhanceOptions()
    /// 死白档（310），白纸。
    public static let maximum = PaperEnhanceOptions(whiteness: maximumWhiteness)
}

// MARK: - 增强器

public enum PaperEnhancer {
    /// 形态学核宽相对图宽的比例（3.78%）。参考实现在 2669px 宽的图上用 101 → 101/2669 ≈ 3.78%。
    /// 小图按比例缩小（不得小于 1），大图按比例放大——**底色估计必须按图宽自适应**。
    public static let paperKernelRatio: Double = 0.0378

    /// 按图宽自适应取核宽（最近奇数，且不超过短边）。
    public static func kernelSize(forWidth width: Int, height: Int) -> Int {
        let target = Int((Double(width) * paperKernelRatio).rounded())
        var kernel = max(target, 3)
        if kernel % 2 == 0 { kernel += 1 }
        let limit = max(min(width, height), 1)
        while kernel > limit, kernel > 1 { kernel -= 2 }
        return max(kernel, 1)
    }

    /// 纸张增强主入口。
    ///
    /// - `options == nil` → 原样返回（**逐字节 no-op**，不重采样）。
    /// - 非 3 通道（RGB）图 → 原样返回：本契约只面向三通道。
    /// - 输入含非有限值（NaN / ±∞）→ 该值按 0 参与运算（排序与分位需要全序；不崩、行为确定）。
    /// - 输出为同尺寸三通道 `FloatImage`（编码域 [0,1]），通道数与输入一致（恒 3）。
    public static func enhance(_ image: FloatImage, options: PaperEnhanceOptions?) -> FloatImage {
        guard let options, image.channels == 3 else { return image }
        let width = image.width
        let height = image.height
        let planeSize = width * height

        // ① 非有限值 → 0（`encoded` 与 `image.values` 同缓冲：全有限时不做拷贝）。
        let encoded: [Float]
        if image.values.allSatisfy({ $0.isFinite }) {
            encoded = image.values
        } else {
            encoded = image.values.map { $0.isFinite ? $0 : 0 }
        }

        // ② 编码域亮度（顺序与参考实现一致）。
        let gray = luminance(encoded, planeSize: planeSize)
        // ③ 线性域灰度 + 大核形态学闭 → 纸面底色。
        let grayLinear = SRGBTransfer.decode(gray)
        let kernel = kernelSize(forWidth: width, height: height)
        let background = LinearMorphology.close(grayLinear, width: width, height: height, kernel: kernel)

        // ④ 分位与纸面参考。
        var sortedBackground = background
        sortedBackground.sort()
        var shadowFloor = Float(Self.interpolatedQuantile(sorted: sortedBackground, quantile: 0.92))
        let paperThreshold = Float(Self.interpolatedQuantile(sorted: sortedBackground, quantile: 0.80))
        sortedBackground = []

        var paperSamples = [Float]()
        paperSamples.reserveCapacity(planeSize / 4)
        for index in 0 ..< planeSize where background[index] >= paperThreshold {
            paperSamples.append(grayLinear[index])
        }
        paperSamples.sort()
        let paperReference = Float(Self.interpolatedQuantile(sorted: paperSamples, quantile: 0.5))
        paperSamples = []

        // ⑤ 亮度单增益：先抹平阴影（bg → shadowFloor），再把纸面亮度映到目标白度。
        let whiteness = min(max(options.whiteness, 0), PaperEnhanceOptions.maximumWhiteness)
        let targetLinear = SRGBTransfer.decodeScalar(Float(whiteness / 255))
        let paperScale = paperReference > 0 ? targetLinear / paperReference : 0

        var gain = [Float](repeating: 0, count: planeSize)
        var epsilon: Float = 1e-6
        vDSP_vthr(background, 1, &epsilon, &gain, 1, vDSP_Length(planeSize))
        vDSP_svdiv(&shadowFloor, gain, 1, &gain, 1, vDSP_Length(planeSize))
        var scale = paperScale
        vDSP_vsmul(gain, 1, &scale, &gain, 1, vDSP_Length(planeSize))

        // ⑥ 逐通道施加增益 + 乘性纸色 + 回编码域。
        let tint = SRGBTransfer.decodeComponents(options.paperColor)
        var output = [Float](repeating: 0, count: planeSize * 3)
        var lower: Float = 0
        var upper: Float = 1
        for channel in 0 ..< 3 {
            var plane = Array(encoded[channel * planeSize ..< (channel + 1) * planeSize])
            plane = SRGBTransfer.decode(plane)
            vDSP_vmul(plane, 1, gain, 1, &plane, 1, vDSP_Length(planeSize))
            // 先钳制再着色（参考实现同序；着色后再钳制为冗余保护）。
            vDSP_vclip(plane, 1, &lower, &upper, &plane, 1, vDSP_Length(planeSize))
            var component = tint[channel]
            vDSP_vsmul(plane, 1, &component, &plane, 1, vDSP_Length(planeSize))
            vDSP_vclip(plane, 1, &lower, &upper, &plane, 1, vDSP_Length(planeSize))
            let result = SRGBTransfer.encode(plane)
            output.replaceSubrange(channel * planeSize ..< (channel + 1) * planeSize, with: result)
        }
        return FloatImage(width: width, height: height, channels: 3, values: output)
    }

    /// 编码域亮度：`0.299·R + 0.587·G + 0.114·B`（BT.601 系数，**与参考实现同序**）。
    private static func luminance(_ planes: [Float], planeSize: Int) -> [Float] {
        var gray = [Float](repeating: 0, count: planeSize)
        var red: Float = 0.299
        var green: Float = 0.587
        var blue: Float = 0.114
        planes.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            vDSP_vsmul(base, 1, &red, &gray, 1, vDSP_Length(planeSize))
            vDSP_vsma(base + planeSize, 1, &green, gray, 1, &gray, 1, vDSP_Length(planeSize))
            vDSP_vsma(base + 2 * planeSize, 1, &blue, gray, 1, &gray, 1, vDSP_Length(planeSize))
        }
        return gray
    }

    /// 分位（`np.percentile` 默认的线性插值口径）：`x[q·(n−1)]` 处线性插值。
    static func interpolatedQuantile(sorted values: [Float], quantile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let position = min(max(quantile, 0), 1) * Double(values.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, values.count - 1)
        let fraction = position - Double(lower)
        let low = Double(values[lower])
        let high = Double(values[upper])
        return low + (high - low) * fraction
    }
}

// MARK: - sRGB 传递函数

/// sRGB ↔ 线性。数组走 4096 段查表 + `vDSP_vlint` 线性插值（误差 ≪ 1/255）；标量走直接计算
/// （与参考实现同为 float32 运算）。
enum SRGBTransfer {
    static let tableIntervals = 4096

    static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    static func encoded(_ value: Double) -> Double {
        value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    /// [0,1] 编码域 → 线性域的查表（`tableIntervals + 1` 个点）。
    static let decodeTable: [Float] = (0 ... tableIntervals).map {
        Float(linear(Double($0) / Double(tableIntervals)))
    }

    /// 线性域 [0,1] → 编码域 [0,1] 的查表。
    static let encodeTable: [Float] = (0 ... tableIntervals).map {
        Float(encoded(Double($0) / Double(tableIntervals)))
    }

    /// 标量：编码 → 线性（与参考实现同精度：float32 直接算）。
    static func decodeScalar(_ value: Float) -> Float {
        value <= 0.04045 ? value / 12.92 : powf((value + 0.055) / 1.055, 2.4)
    }

    /// 标量：线性 → 编码。
    static func encodeScalar(_ value: Float) -> Float {
        value <= 0.0031308 ? value * 12.92 : 1.055 * powf(value, 1 / 2.4) - 0.055
    }

    static func decodeComponents(_ color: PaperColor) -> [Float] {
        [Float(color.red) / 255, Float(color.green) / 255, Float(color.blue) / 255]
            .map(decodeScalar)
    }

    /// 整平面查表插值（非有限值按 0 处理）。
    static func apply(_ values: [Float], table: [Float]) -> [Float] {
        let count = values.count
        var output = [Float](repeating: 0, count: count)
        var scale: Float = Float(tableIntervals)
        var lower: Float = 0
        var upper: Float = Float(tableIntervals) - 0.001
        var indices = [Float](repeating: 0, count: count)
        vDSP_vsmul(values, 1, &scale, &indices, 1, vDSP_Length(count))
        vDSP_vclip(indices, 1, &lower, &upper, &indices, 1, vDSP_Length(count))
        vDSP_vlint(table, indices, 1, &output, 1, vDSP_Length(count), vDSP_Length(table.count))
        return output
    }

    static func decode(_ values: [Float]) -> [Float] { apply(values, table: decodeTable) }
    static func encode(_ values: [Float]) -> [Float] { apply(values, table: encodeTable) }
}
