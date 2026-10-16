// PhotoScanRunner —— 拍摄后的「自动检测 → 几何矫正」编排（App 层，装配点见 AppCompositionRoot.swift）。
//
// 复用组合根已装配的两个后端，**不新增第二份实现**：
//   像素位图 → `ImageDocumentDetecting`（Vision 段分割 + 矩形回退）出归一化四角
//            → `CoreImagePerspectiveCorrector`（几何在 Core 的 `DocumentRectifier`）出摆正后的位图。
// 检测不到文档 → 原样抛 `ScannerError.documentNotFound`，由 UI 收敛成一行原因。
//
// 本类型不含平台采集 API，也**不在主线程跑**：调用方用 `Task.detached` 调用（P0 线程纪律）。
import CoreGraphics
import DDScannerCore
import DDScannerVision
import Foundation

/// 一次「自动检测 → 几何矫正」的结果。
struct PhotoScanResult: Sendable {
    /// 矫正后的位图（已按文档四角摆正、裁到文档边界）。
    let image: CGImage
    /// 文档检测置信度 ∈ [0,1]。
    let confidence: Float
}

struct PhotoScanRunner: Sendable {
    let detector: ImageDocumentDetecting
    let corrector: CoreImagePerspectiveCorrector

    /// 全分辨率路径：检测四角 → 透视矫正 + 裁切。
    /// - Parameter image: 已按 EXIF 摆正的位图（见 `CapturedPhotoDecoder`）。
    /// - Throws: 检测不到文档抛 `ScannerError.documentNotFound`，单应无解抛 `homographyNotSolvable`。
    func scan(_ image: CGImage) throws -> PhotoScanResult {
        let detection = try detector.detectDocument(in: image)
        let corrected = try corrector.correctedImage(from: image, quad: detection.quad)
        AppLog.info(
            "拍摄矫正完成：\(image.width)×\(image.height) → \(corrected.width)×\(corrected.height)"
                + "（检测置信度 \(String(format: "%.3f", detection.confidence))）",
            category: .capture
        )
        return PhotoScanResult(image: corrected, confidence: detection.confidence)
    }
}
