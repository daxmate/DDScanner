// 开发用「读入自测图片」的读取器（仅 DEBUG；相册选图与内置样例走**同一条**读入路径）。
//
// 为什么用 ImageIO：12MP 照片若整幅全解码（4 通道约 48 MB+）会 OOM，故在读入阶段就用
// `kCGImageSourceThumbnailMaxPixelSize` 把最长边限到 4032px（按比例降采样）；同时用
// `kCGImageSourceCreateThumbnailWithTransform` 摆正 EXIF 方向，避免相册竖拍照片侧躺。
//
// 本文件刻意只依赖 Foundation / ImageIO / CoreGraphics（不 import UIKit），
// 因此可在 macOS 上单独编译跑失败路径验证（见报告「反向验证」）。
#if DEBUG
    import CoreGraphics
    import Foundation
    import ImageIO

    /// 一次读入的结果：位图 + 尺寸账（源图 / 实际读入）+ 载入耗时。
    struct DevPhotoLoadResult {
        /// 已按最长边上限降采样、并按 EXIF 方向摆正的位图。
        let image: CGImage
        /// 源图（应用 EXIF 方向后）的像素尺寸；来自元数据，无需解码像素。
        let sourceWidth: Int
        let sourceHeight: Int
        /// 载入耗时（建图像源 + 降采样解码），毫秒。
        let loadMilliseconds: Double

        var sourceSizeText: String {
            "\(sourceWidth)×\(sourceHeight)"
        }

        /// 实际读入尺寸；被降采样时把原因一起写出来，便于和源图尺寸对账。
        var loadedSizeText: String {
            let size = "\(image.width)×\(image.height)"
            guard isDownsampled else { return size }
            return "\(size)（源图最长边 > \(DevPhotoLoader.maximumPixelSize)px，已按比例降采样）"
        }

        /// 实际读入是否被降采样（判据：源图最长边超过上限）。
        var isDownsampled: Bool {
            max(sourceWidth, sourceHeight) > DevPhotoLoader.maximumPixelSize
        }
    }

    enum DevPhotoLoadError: Error, CustomStringConvertible {
        case emptyData
        case unreadableImage
        case invalidDimensions(width: Int, height: Int)
        case decodeFailed
        case oversizedRead(width: Int, height: Int)

        var description: String {
            switch self {
            case .emptyData: return "所选条目没有可读数据（data 为空）"
            case .unreadableImage: return "无法识别的图片格式（ImageIO 建不出图像源）"
            case let .invalidDimensions(width, height): return "图片尺寸非法（\(width)×\(height)）"
            case .decodeFailed: return "图片解码失败（可能已损坏或格式不受支持）"
            case let .oversizedRead(width, height): return "降采样结果仍超上限（\(width)×\(height)）"
            }
        }
    }

    enum DevPhotoLoader {
        /// 读入时最长边上限：4032px（12MP 量级）。超出即按比例降采样，绝不整图全解码。
        static let maximumPixelSize = 4032

        /// 从内存数据读入：读元数据算尺寸 → 按上限降采样解码（顺带摆正方向）。
        static func load(data: Data) throws -> DevPhotoLoadResult {
            let start = CFAbsoluteTimeGetCurrent()
            guard !data.isEmpty else { throw DevPhotoLoadError.emptyData }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0 else {
                throw DevPhotoLoadError.unreadableImage
            }

            let (rawWidth, rawHeight) = rawPixelSize(of: source)
            let (sourceWidth, sourceHeight) = orientedSize(
                width: rawWidth,
                height: rawHeight,
                orientation: exifOrientation(of: source)
            )
            guard sourceWidth > 0, sourceHeight > 0 else {
                throw DevPhotoLoadError.invalidDimensions(width: sourceWidth, height: sourceHeight)
            }

            let limit = min(max(sourceWidth, sourceHeight), maximumPixelSize)
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: limit,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw DevPhotoLoadError.decodeFailed
            }
            guard image.width > 0, image.height > 0, max(image.width, image.height) <= maximumPixelSize else {
                throw DevPhotoLoadError.oversizedRead(width: image.width, height: image.height)
            }

            return DevPhotoLoadResult(
                image: image,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                loadMilliseconds: (CFAbsoluteTimeGetCurrent() - start) * 1000
            )
        }

        /// 元数据里的像素宽高（只读属性，不解码像素）。
        private static func rawPixelSize(of source: CGImageSource) -> (Int, Int) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
                return (0, 0)
            }
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            return (width, height)
        }

        /// EXIF 方向（缺失或非法一律按 .up 处理）。
        private static func exifOrientation(of source: CGImageSource) -> CGImagePropertyOrientation {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let raw = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value,
                  let orientation = CGImagePropertyOrientation(rawValue: raw) else {
                return .up
            }
            return orientation
        }

        /// 应用 EXIF 方向后的显示尺寸（旋转 90°/270° 时宽高互换）。
        private static func orientedSize(
            width: Int,
            height: Int,
            orientation: CGImagePropertyOrientation
        ) -> (Int, Int) {
            switch orientation {
            case .left, .right, .leftMirrored, .rightMirrored: return (height, width)
            default: return (width, height)
            }
        }
    }
#endif
