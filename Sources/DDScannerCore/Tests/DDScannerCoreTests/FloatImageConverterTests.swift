// FloatImageConverter 正确性测试：vImage 路径 vs 旧的 CGContext + 标量参考路径。
//
// 缩放的插值核不是同一个（CoreGraphics `.high` vs vImage 高质量重采样），所以**不做逐点等价**
// 断言；契约落在三件能钉死语义的事上：
//   ① 纯色图：任何插值核都必须给出同一个值 → 逐点等于原色；
//   ② 同尺寸（不缩放）：两条路径都只做格式转换 → 逐点一致到量化误差以内；
//   ③ 缩放：尺寸/通道/值域正确，且与参考路径在平滑图上足够接近（防"缩错区域/缩错方向"）。
import CoreGraphics
import DDScannerCore
import Foundation
import Testing

@Suite("FloatImageConverter（vImage）")
struct FloatImageConverterTests {
    /// 造一张 RGBA8888 位图（值由闭包给出，RGB 相同 → 灰度测试图）。
    private static func makeImage(
        width: Int,
        height: Int,
        color: (Int, Int) -> (UInt8, UInt8, UInt8)
    ) -> CGImage {
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let pixel = y * bytesPerRow + x * 4
                let (red, green, blue) = color(x, y)
                buffer[pixel] = red
                buffer[pixel + 1] = green
                buffer[pixel + 2] = blue
                buffer[pixel + 3] = 255
            }
        }
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
        precondition(context != nil, "测试用位图上下文建不出来")
        buffer.withUnsafeMutableBytes { raw in
            context?.data?.copyMemory(from: raw.baseAddress!, byteCount: bytesPerRow * height)
        }
        return context!.makeImage()!
    }

    private static func maxAbsoluteDifference(_ lhs: FloatImage, _ rhs: FloatImage) -> Float {
        var maximum: Float = 0
        for index in 0 ..< lhs.values.count {
            maximum = max(maximum, abs(lhs.values[index] - rhs.values[index]))
        }
        return maximum
    }

    @Test("纯色图 → 任意目标尺寸都得到同一颜色（插值核无关）")
    func solidColorSurvivesAnyScaling() throws {
        let image = Self.makeImage(width: 32, height: 24) { _, _ in (128, 64, 32) }
        for (width, height) in [(16, 12), (48, 36), (488, 712)] {
            let output = try FloatImageConverter.rgb(from: image, width: width, height: height)
            #expect(output.width == width && output.height == height && output.channels == 3)
            for channel in 0 ..< 3 {
                let expected: Float = channel == 0 ? 128.0 / 255 : (channel == 1 ? 64.0 / 255 : 32.0 / 255)
                let values = output.values[channel * (width * height) ..< (channel + 1) * (width * height)]
                let channelIsPure = values.allSatisfy { abs($0 - expected) < 1e-5 }
                #expect(channelIsPure, "通道 \(channel) 不纯")
            }
        }
    }

    @Test("同尺寸（不缩放）：vImage 路径与参考路径逐点一致到量化误差内")
    func sameSizeMatchesReference() throws {
        let image = Self.makeImage(width: 37, height: 23) { x, y in
            (UInt8(x * 6 % 256), UInt8(y * 9 % 256), UInt8((x + y) * 4 % 256))
        }
        let converted = try FloatImageConverter.rgb(from: image, width: 37, height: 23)
        let reference = try LegacyFloatImageReference.rgb(from: image, width: 37, height: 23)
        #expect(Self.maxAbsoluteDifference(converted, reference) <= 1e-6)
    }

    @Test("缩放：两张平滑图结果与参考路径接近（不漏区域、不反方向）")
    func downscaleStaysCloseToReference() throws {
        let image = Self.makeImage(width: 64, height: 48) { x, y in
            (UInt8(x * 4), UInt8(y * 5), UInt8((x + y) * 2))
        }
        let converted = try FloatImageConverter.rgb(from: image, width: 32, height: 24)
        let reference = try LegacyFloatImageReference.rgb(from: image, width: 32, height: 24)
        #expect(converted.width == 32 && converted.height == 24)
        let convertedInRange = converted.values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
        #expect(convertedInRange)

        var maximum: Float = 0
        var total: Double = 0
        for index in 0 ..< converted.values.count {
            let difference = abs(converted.values[index] - reference.values[index])
            maximum = max(maximum, difference)
            total += Double(difference)
        }
        let mean = Float(total / Double(converted.values.count))
        #expect(mean <= 0.02, "平均绝对差 \(mean) 偏大，两路径缩放的区域/方向可能不一致")
        #expect(maximum <= 0.15, "最大绝对差 \(maximum) 偏大")
    }

    @Test("上采样：仍输出请求的尺寸，值域合法")
    func upscaleProducesRequestedSize() throws {
        let image = Self.makeImage(width: 16, height: 12) { x, y in (UInt8(x * 8), UInt8(y * 10), 0) }
        let output = try FloatImageConverter.rgb(from: image, width: 40, height: 30)
        #expect(output.width == 40 && output.height == 30 && output.channels == 3)
        let outputInRange = output.values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
        #expect(outputInRange)
    }

    @Test("非法目标尺寸 → 抛错（不崩）")
    func rejectsInvalidTargetSize() {
        let image = Self.makeImage(width: 8, height: 8) { _, _ in (1, 2, 3) }
        #expect(throws: FloatImageConverter.Error.self) {
            _ = try FloatImageConverter.rgb(from: image, width: 0, height: 8)
        }
        #expect(throws: FloatImageConverter.Error.self) {
            _ = try FloatImageConverter.rgb(from: image, width: 8, height: -1)
        }
    }
}
