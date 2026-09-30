// FloatImageConverter —— CGImage → Float32 平面图（RGB，[0,1]）的向量化转换（vImage）。
//
// 之前这段逻辑写在 App 的 DEBUG 自测页里（CGContext + 逐像素标量循环），真机首测显示
// 「预处理（缩放到 488×712）」耗时 66.89 ms。这里把它下沉到 Core（只依赖 CoreGraphics /
// Accelerate，仍平台无关、可在本机单测），并改用 vImage：
//   ① `vImageBuffer_InitWithCGImage` 取源位图（ARGB8888，不做缩放）；
//   ② `vImageScale_ARGB8888` 缩放到目标尺寸（保持「拉伸到精确尺寸、不保长宽比」的原语义）；
//   ③ `vImageConvert_ARGB8888toPlanar8` 拆平面，`vImageConvert_Planar8toPlanarF` 映射到 [0,1]。
// 全程 Float32；不引入半精度。
//
// ⚠️ 缓冲一律手工分配（`makeBuffer`）：实测 `vImageBuffer_Init` 对 32bpp 缓冲给出的 rowBytes
// 与 width×4 不符（16 宽给出 128 字节行距），会让 Scale 写出的像素按错位行距被读回——这是本
// 文件不用它的原因。src（`vImageBuffer_InitWithCGImage`）由 malloc 分配，用 `free` 释放。
import Accelerate
import CoreGraphics
import Foundation

public enum FloatImageConverter {
    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case invalidTargetSize(width: Int, height: Int)
        case unsupportedSourceImage
        case scalingFailed(code: Int)
        case planarConversionFailed(code: Int)

        public var description: String {
            switch self {
            case let .invalidTargetSize(width, height): return "目标尺寸非法（\(width)×\(height)）"
            case .unsupportedSourceImage: return "位图无法转成 vImage 缓冲（格式不受支持）"
            case let .scalingFailed(code): return "vImage 缩放失败（vImage_Error \(code)）"
            case let .planarConversionFailed(code): return "vImage 平面拆分失败（vImage_Error \(code)）"
            }
        }
    }

    /// 把 `image` 缩放（拉伸）到 `width × height`，转成 RGB 三平面 Float32 图（值域 [0,1]）。
    public static func rgb(from image: CGImage, width: Int, height: Int) throws -> FloatImage {
        guard width > 0, height > 0, image.width > 0, image.height > 0 else {
            throw Error.invalidTargetSize(width: width, height: height)
        }
        guard var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
        ) else {
            throw Error.unsupportedSourceImage
        }

        var source = vImage_Buffer()
        let initStatus = vImageBuffer_InitWithCGImage(&source, &format, nil, image, vImage_Flags(kvImageNoFlags))
        guard initStatus == kvImageNoError else { throw Error.unsupportedSourceImage }
        defer { free(source.data) }

        var target = makeBuffer(width: width, height: height, bytesPerPixel: 4)
        defer { target.data.deallocate() }
        // 缩放滤波器：默认（面积/多抽头抗锯齿）实测 8.2ms，`kvImageHighQualityResampling`
        // （Lanczos 级）实测 17.3ms（3024×4032 → 488×712，本机 release）——后者会把整步推到
        // 10ms 目标之上，故用默认滤波器；与原 CGContext `.high` 的接近程度由
        // `FloatImageConverterTests.downscaleStaysCloseToReference` 守着。
        let scaleStatus = vImageScale_ARGB8888(&source, &target, nil, vImage_Flags(kvImageNoFlags))
        guard scaleStatus == kvImageNoError else { throw Error.scalingFailed(code: Int(scaleStatus)) }

        var alpha = makeBuffer(width: width, height: height, bytesPerPixel: 1)
        var red = makeBuffer(width: width, height: height, bytesPerPixel: 1)
        var green = makeBuffer(width: width, height: height, bytesPerPixel: 1)
        var blue = makeBuffer(width: width, height: height, bytesPerPixel: 1)
        defer {
            alpha.data.deallocate()
            red.data.deallocate()
            green.data.deallocate()
            blue.data.deallocate()
        }
        let deinterleaveStatus = vImageConvert_ARGB8888toPlanar8(
            &target, &alpha, &red, &green, &blue, vImage_Flags(kvImageNoFlags)
        )
        guard deinterleaveStatus == kvImageNoError else {
            throw Error.planarConversionFailed(code: Int(deinterleaveStatus))
        }

        let planeSize = width * height
        var values = [Float](repeating: 0, count: planeSize * 3)
        try values.withUnsafeMutableBufferPointer { output in
            for (index, plane) in [red, green, blue].enumerated() {
                var sourcePlane = plane
                var floatPlane = makeBuffer(width: width, height: height, bytesPerPixel: 4)
                defer { floatPlane.data.deallocate() }
                let status = vImageConvert_Planar8toPlanarF(
                    &sourcePlane, &floatPlane, 1.0, 0.0, vImage_Flags(kvImageNoFlags)
                )
                guard status == kvImageNoError else {
                    throw Error.planarConversionFailed(code: Int(status))
                }
                let destination = output.baseAddress! + index * planeSize
                destination.update(from: floatPlane.data.assumingMemoryBound(to: Float.self), count: planeSize)
            }
        }
        return FloatImage(width: width, height: height, channels: 3, values: values)
    }

    /// Float32 平面图 → `CGImage`（仅取前 3 通道作 RGB8；预览与后续处理共用）。
    ///
    /// 放在 Core 的理由：平台层（App 自测页 / Vision 成像）都要把重采样结果画回来；
    /// 只保留**一份**转换实现，避免各层各写一份（且可脱离模拟器在本机单测）。
    ///
    /// 实现已**向量化**（Accelerate / vDSP）：逐像素标量循环（8.08 Mpx 输出 = 8.08 M 像素 ×
    /// 3 通道）改为「逐通道整平面缩放/钳制 + 一次带菱形步长的取整写回」。数值语义与旧实现
    /// **逐字节一致**（见 `rgbPixelBuffer`），由 `PixelRenderingEquivalenceTests` 守着。
    public static func makeCGImage(from image: FloatImage) -> CGImage? {
        guard let buffer = rgbPixelBuffer(from: image) else { return nil }
        guard let provider = CGDataProvider(data: Data(buffer) as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        return CGImage(
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    /// Float32 平面图 → 行优先 `R,G,B,X` 像素缓冲（`X` 恒为 255；缺少的通道也为 255）。
    /// 通道数非法（≤ 0）时返回 `nil`。
    ///
    /// 数值语义 = 旧逐像素实现 `UInt8(max(0, min(255, value * 255)).rounded())`，逐字节一致：
    ///   ① `value * 255` 与钳制都在 **Float** 域（与旧实现同精度、同顺序）；
    ///   ② 取整走 **Double**：`Float → Double` 无损，`+ 0.5` 在 Double 内**精确**（x ∈ [0,255]
    ///      时 `x + 0.5` 最多 25 位有效位，53 位尾数足包容），再截断 ——
    ///      对非负值等价于「四舍五入、半值远离零」，即 `.rounded()` 的默认语义；
    ///   ③ 非有限值先按旧实现的 min/max 语义归一（NaN / +∞ → 255，-∞ → 0）。
    static func rgbPixelBuffer(from image: FloatImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        let planeSize = width * height
        let channels = min(image.channels, 3)
        guard channels > 0 else { return nil }

        // 未使用的通道与 X 字节保持 255（与旧实现「缓冲初始化为 255」一致）。
        var buffer = [UInt8](repeating: 255, count: planeSize * 4)

        // 非有限值：旧实现 `max(0, min(255, value * 255))` 下 NaN / +∞ → 255（→1.0）、-∞ → 0。
        // 正常路径（全有限）不拷贝，直接引用原缓冲。
        let source: [Float]
        if allValuesAreFinite(image.values) {
            source = image.values
        } else {
            var sanitized = image.values
            for index in sanitized.indices where !sanitized[index].isFinite {
                sanitized[index] = sanitized[index] < 0 ? 0 : 1
            }
            source = sanitized
        }

        source.withUnsafeBufferPointer { sourcePointer in
            buffer.withUnsafeMutableBufferPointer { outputPointer in
                guard let base = sourcePointer.baseAddress, let destination = outputPointer.baseAddress else {
                    return
                }
                let count = vDSP_Length(planeSize)
                var scaled = [Float](repeating: 0, count: planeSize)
                var widened = [Double](repeating: 0, count: planeSize)
                var scaleValue: Float = 255
                var lower: Float = 0
                var upper: Float = 255
                var half: Double = 0.5
                for channel in 0 ..< channels {
                    let plane = base + channel * planeSize
                    vDSP_vsmul(plane, 1, &scaleValue, &scaled, 1, count)
                    vDSP_vclip(scaled, 1, &lower, &upper, &scaled, 1, count)
                    vDSP_vspdp(scaled, 1, &widened, 1, count)
                    vDSP_vsaddD(widened, 1, &half, &widened, 1, count)
                    // 输出步长 4：直接写进交错缓冲的第 channel 个字节。
                    vDSP_vfixu8D(widened, 1, destination.advanced(by: channel), 4, count)
                }
            }
        }
        return buffer
    }

    /// 全部元素有限？（vDSP 求和：NaN / ±∞ 会传播出来 → 非有限 ⇒ false。）
    private static func allValuesAreFinite(_ values: [Float]) -> Bool {
        guard !values.isEmpty else { return true }
        var total: Float = 0
        values.withUnsafeBufferPointer { buffer in
            vDSP_sve(buffer.baseAddress!, 1, &total, vDSP_Length(values.count))
        }
        return total.isFinite
    }

    /// 手工分配一个 64 字节对齐、行距恰为 `width × bytesPerPixel` 的 vImage 缓冲。
    private static func makeBuffer(width: Int, height: Int, bytesPerPixel: Int) -> vImage_Buffer {
        let rowBytes = width * bytesPerPixel
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: rowBytes * height, alignment: 64)
        return vImage_Buffer(
            data: pointer,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: rowBytes
        )
    }
}
