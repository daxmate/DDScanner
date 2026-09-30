// ⚠️ test-only reference —— 旧的「CGContext 缩放 + 逐像素标量循环」图像读取实现。
//
// 这是 8f0dfd5 上 `App/Dev/DewarpSelfTestRunner.swift` 里 `UIImage.floatImage(width:height:)`
// 的逐行拷贝（去掉 UIImage 包装，改成收 CGImage）。只作参照物：
//   ① `FloatImageConverterTests` 用它做正确性比对；② 性能基准里作为「改动前」的同口径数字。
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
}
