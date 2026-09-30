// ⚠️ test-only reference —— 旧的图像转换实现（CGContext 缩放 + 逐像素标量循环 / 逐像素写字节）。
//
// 这是 8f0dfd5 上 `App/Dev/DewarpSelfTestRunner.swift` 里 `UIImage.floatImage(width:height:)`
// 与 d96d0a2 上 `FloatImageConverter.makeCGImage` 像素循环的逐行拷贝（去掉 UIImage 包装、把
// 「造 CGImage」换成「返回缓冲」）。只作参照物：
//   ① `FloatImageConverterTests` / `PixelRenderingEquivalenceTests` 用它做正确性比对；
//   ② 性能基准里作为「改动前」的同口径数字。
import CoreGraphics
import DDScannerCore
import Foundation

enum LegacyFloatImageReference {
    enum ConversionError: Error {
        case imageConversionFailed
    }

    /// 缩放到指定尺寸并转成 Float32 RGB（[0,1]）平面图（旧实现：CGContext `.high` + 标量循环）。
    static func rgb(from image: CGImage, width: Int, height: Int) throws -> FloatImage {
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let rendered: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw ConversionError.imageConversionFailed }

        let plane = width * height
        var values = [Float](repeating: 0, count: plane * 3)
        for index in 0 ..< plane {
            let pixel = index * 4
            values[index] = Float(buffer[pixel]) / 255
            values[plane + index] = Float(buffer[pixel + 1]) / 255
            values[2 * plane + index] = Float(buffer[pixel + 2]) / 255
        }
        return FloatImage(width: width, height: height, channels: 3, values: values)
    }

    /// Float32 平面图 → 行优先 `R,G,B,X` 像素缓冲（旧实现：逐像素标量循环 + `.rounded()`）。
    ///
    /// 本函数是 d96d0a2 上 `FloatImageConverter.makeCGImage` 像素循环的逐行拷贝（只把
    /// 「造 CGImage」换成「返回缓冲」，便于逐字节比对）。`PixelRenderingEquivalenceTests` 用它
    /// 证明向量化路径与旧实现的字节输出完全一致。
    static func pixelBuffer(from image: FloatImage) -> [UInt8]? {
        let planeSize = image.width * image.height
        let channels = min(image.channels, 3)
        guard channels > 0 else { return nil }
        var buffer = [UInt8](repeating: 255, count: planeSize * 4)
        for index in 0 ..< planeSize {
            let pixel = index * 4
            for channel in 0 ..< channels {
                let value = image.values[channel * planeSize + index]
                buffer[pixel + channel] = UInt8(max(0, min(255, value * 255)).rounded())
            }
        }
        return buffer
    }
}
