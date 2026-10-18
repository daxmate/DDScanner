// CapturedPhotoDecoder —— 相机原始数据 → 已按 EXIF 摆正、限长边的 `CGImage`（App 层，见 docs/architecture.md 批 B1）。
//
// 与开发自测页的 `DevPhotoLoader` 同一套 ImageIO 手法，但**不带 `#if DEBUG`**（生产路径）：
//   - `kCGImageSourceCreateThumbnailWithTransform` 摆正 EXIF 方向（竖拍照片不侧躺）；
//   - 最长边封顶到 `maximumPixelSize`（4032px）：这是**挡 >12MP 源的守卫**，不是降采样——
//     12MP 量级照片的原始长边就是 4032px，原样通过；只有更大的源（如 48MP）才会被缩到上限。
//     理由：整幅全解码约 48MB 会 OOM，且 Core 的大图守卫
//     （`GridResampler.maximumSourcePixelCount` = 2^24）也要求源平面像素数受限。
//
// 只依赖 Foundation / ImageIO / CoreGraphics（不 import UIKit），可脱离 App 编译。
import CoreGraphics
import Foundation
import ImageIO

/// 解码失败原因（App 层错误，不污染 Core 的 `ScannerError`）。
enum CapturedPhotoDecodeError: Error, Equatable {
    case emptyData
    case unreadableImage
    case renderFailed
}

enum CapturedPhotoDecoder {
    /// 读入时最长边封顶：4032px（挡 >12MP 源，非降采样）。
    static let maximumPixelSize = 4032

    /// 把一次拍摄的原始编码数据解成位图：方向已摆正、最长边封顶到 `maximumPixelSize`。
    static func decode(_ data: Data, maximumPixelSize: Int = maximumPixelSize) throws -> CGImage {
        guard !data.isEmpty else { throw CapturedPhotoDecodeError.emptyData }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw CapturedPhotoDecodeError.unreadableImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CapturedPhotoDecodeError.renderFailed
        }
        return image
    }
}
