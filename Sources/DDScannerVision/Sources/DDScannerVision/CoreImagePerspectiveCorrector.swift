// CoreImagePerspectiveCorrector —— 透视校正 + 裁切的平台成像层（见 docs/architecture.md）。
//
// 分工（本批明确）：**几何全部在 Core**（`DocumentRectifier` 解单应、估目标尺寸、生成采样网格），
// 本文件只做「平台调用与成像」——把 `CGImage` 交给 Core 转成 Float32 平面图、调用 Core 的
// `DocumentRectifier.rectify`（内部走 `GridResampler` 这个**唯一**重采样入口），再把结果渲染回
// `CGImage`。
//
// 为什么不在本层用 `CIFilter.perspectiveCorrection` 另做一份像素重采样：Core 的 `GridResampler`
// 已经是产品路径唯一的采样实现（且必须留在 Swift 侧 Float32，见 Tools/ModelConvert/README.md），
// 本批要求「不要写第二份重采样实现」——透视裁切同样走它，保证几何/采样只有一条实现、且可在本机
// `swift test` 验证（`DocumentRectifierTests`）。
import CoreGraphics
import DDScannerCore
import Foundation

/// 透视校正后端：Core 几何 + CoreGraphics 成像。
public struct CoreImagePerspectiveCorrector: PerspectiveCorrecting {
    public init() {}

    /// 四角 → 单应矩阵（几何在 Core）。
    public func homography(for quad: DocumentQuad) throws -> Homography {
        guard let homography = Homography(mapping: quad) else {
            throw ScannerError.homographyNotSolvable
        }
        AppLog.debug("透视校正矩阵求解完成", category: .vision)
        return homography
    }

    /// 按四角把位图矫正 + 裁切成正面矩形（全分辨率），返回新的 `CGImage`。
    ///
    /// - Parameters:
    ///   - image: 源位图（像素已按 EXIF 摆正）。
    ///   - quad: 文档四角（归一化，TL→TR→BR→BL，左上原点）。
    ///   - scale: 输出相对文档实际像素尺寸的缩放；默认 1 = 全分辨率。
    public func correctedImage(from image: CGImage, quad: DocumentQuad, scale: Double = 1) throws -> CGImage {
        let source = try FloatImageConverter.rgb(from: image, width: image.width, height: image.height)
        let rectified = try DocumentRectifier.rectify(source, quad: quad, scale: scale)
        guard let output = FloatImageConverter.makeCGImage(from: rectified) else {
            throw ScannerError.stageNotConfigured("CoreImagePerspectiveCorrector（结果渲染失败）")
        }
        AppLog.debug(
            "透视校正完成：\(image.width)×\(image.height) → \(output.width)×\(output.height)",
            category: .vision
        )
        return output
    }
}
