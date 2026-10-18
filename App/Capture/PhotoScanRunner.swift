// PhotoScanRunner —— 拍摄后的「自动检测 → 几何矫正」编排（App 层，装配点见 AppCompositionRoot.swift）。
//
// 复用组合根已装配的两个后端，**不新增第二份实现**：
//   像素位图 → `ImageDocumentDetecting`（Vision 段分割 + 矩形回退）出归一化四角
//            → `CoreImagePerspectiveCorrector`（几何在 Core 的 `DocumentRectifier`）出摆正后的位图。
// 检测不到文档 → 原样抛 `ScannerError.documentNotFound`，由 UI 收敛成一行原因。
//
// 本类型不含平台采集 API，也**不在主线程跑**：调用方用 `Task.detached` 调用（P0 线程纪律）。
// 批 B2 起：`scan` 产出 `PhotoScanOutcome`（upright 原图 + 归一化四角 + 首次矫正图 + 置信度），
// 用户拖角确认后走 `correct(image:quad:)` 重新矫正——两条入口复用同一 `CoreImagePerspectiveCorrector`。
import CoreGraphics
import DDScannerCore
import DDScannerVision
import Foundation

/// 一次「拍摄 → 自动检测 → 首次几何矫正」的完整结果。
struct PhotoScanOutcome: Sendable {
    /// 方向已归一化的原图（与编辑器共用同一张 upright 图，坐标空间一致）。
    let uprightImage: CGImage
    /// 检测到的文档四角（归一化，TL → TR → BR → BL）。
    let quad: DocumentQuad
    /// 首次自动矫正后的位图。
    let correctedImage: CGImage
    /// 文档检测置信度 ∈ [0,1]。
    let confidence: Float
}

/// 一次「用指定四角重新矫正」的结果。
struct PhotoScanResult: Sendable {
    /// 重新矫正后的位图。
    let image: CGImage
}

struct PhotoScanRunner: Sendable {
    let detector: ImageDocumentDetecting
    let corrector: CoreImagePerspectiveCorrector

    /// 全路径：检测四角 → 首次透视矫正 + 裁切，带回 upright 原图、四角、矫正图与置信度。
    /// - Parameter image: 已按 EXIF 摆正的位图（见 `CapturedPhotoDecoder`）。
    /// - Throws: 检测不到文档抛 `ScannerError.documentNotFound`，单应无解抛 `homographyNotSolvable`。
    func scan(_ image: CGImage) throws -> PhotoScanOutcome {
        let detection = try detector.detectDocument(in: image)
        let corrected = try corrector.correctedImage(from: image, quad: detection.quad)
        AppLog.info(
            "拍摄矫正完成：\(image.width)×\(image.height) → \(corrected.width)×\(corrected.height)"
                + "（检测置信度 \(String(format: "%.3f", detection.confidence))）",
            category: .capture
        )
        return PhotoScanOutcome(
            uprightImage: image,
            quad: detection.quad,
            correctedImage: corrected,
            confidence: detection.confidence
        )
    }

    /// 用用户调整后的归一化四角重新矫正（复用同一 `CoreImagePerspectiveCorrector`，无第二份实现）。
    /// - Parameters:
    ///   - image: upright 原图（与 `scan` 输入同一张）。
    ///   - quad: 调整后的文档四角（归一化，TL → TR → BR → BL）。
    /// - Throws: 单应无解抛 `homographyNotSolvable`，退化四角抛 `degenerateQuad`。
    func correct(_ image: CGImage, quad: DocumentQuad) throws -> PhotoScanResult {
        let corrected = try corrector.correctedImage(from: image, quad: quad)
        AppLog.info(
            "四角微调后重新矫正完成：\(image.width)×\(image.height) → \(corrected.width)×\(corrected.height)",
            category: .capture
        )
        return PhotoScanResult(image: corrected)
    }
}
