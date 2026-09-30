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
