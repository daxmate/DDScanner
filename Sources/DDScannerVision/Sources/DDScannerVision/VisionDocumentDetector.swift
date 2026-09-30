// VisionDocumentDetector —— Apple Vision 文档边界检测（真实现，见 docs/architecture.md）。
//
// 策略：优先 `VNDetectDocumentSegmentationRequest`（iOS 15+ / macOS 12+，专为文档边界训练），
// 失败或不可用时回退 `VNDetectRectanglesRequest`；两者都找不到 → 抛 `ScannerError.documentNotFound`。
//
// 坐标约定（**写死，消费端依赖**）：`DocumentDetection.quad` 为归一化坐标 ∈ [0,1]，
// 原点在**图像左上角**、y 轴**向下**，顺序 **左上 → 右上 → 右下 → 左下**（与 `DocumentQuad` 一致）。
// Vision 自身用「左下角原点、y 轴向上」的归一化坐标，本文件在出口统一翻转到左上角原点。
import CoreGraphics
import DDScannerCore
import Foundation
import Vision

/// Vision 后端文档检测。像素入口 `detectDocument(in: CGImage)` 是真实现。
public struct VisionDocumentDetector: ImageDocumentDetecting, DocumentDetecting {
    public init() {}

    /// 像素 → 文档四角（归一化，TL→TR→BR→BL）+ 置信度；检测不到抛 `documentNotFound`。
    public func detectDocument(in image: CGImage) throws -> DocumentDetection {
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        if #available(iOS 15.0, macOS 12.0, *) {
            do {
                if let detection = try documentSegmentation(handler: handler) { return detection }
                AppLog.debug("文档段分割未命中，回退矩形检测", category: .vision)
            } catch {
                AppLog.warning("文档段分割请求失败，回退矩形检测：\(error)", category: .vision)
            }
        }
        if let detection = try rectangleDetection(handler: handler) { return detection }
        throw ScannerError.documentNotFound
    }

    /// 帧几何入口：`ScanFrame` 不含像素，本入口无法实现（像素管线接线属后续批次）。
    public func detectDocument(in frame: ScanFrame) throws -> DocumentQuad {
        throw ScannerError.stageNotConfigured("VisionDocumentDetector（需像素入口 detectDocument(in: CGImage)）")
    }

    // MARK: - 两种请求

    private func documentSegmentation(handler: VNImageRequestHandler) throws -> DocumentDetection? {
        guard #available(iOS 15.0, macOS 12.0, *) else { return nil }
        let request = VNDetectDocumentSegmentationRequest()
        try handler.perform([request])
        guard let observation = request.results?.first else { return nil }
        return detection(from: observation)
    }

    private func rectangleDetection(handler: VNImageRequestHandler) throws -> DocumentDetection? {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 1
        try handler.perform([request])
        guard let observation = request.results?.first else { return nil }
        return detection(from: observation)
    }

    /// `VNRectangleObservation` → `DocumentDetection`（翻转 y 轴、钳制到单位正方形）。
    private func detection(from observation: VNRectangleObservation) -> DocumentDetection {
        // Vision：原点左下、y 向上 → 本仓：原点左上、y 向下。
        func flipped(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x, y: 1 - point.y)
        }
        let quad = DocumentQuad(
            topLeft: flipped(observation.topLeft),
            topRight: flipped(observation.topRight),
            bottomRight: flipped(observation.bottomRight),
            bottomLeft: flipped(observation.bottomLeft)
        ).clampedToUnitSquare()
        AppLog.debug(
            String(format: "文档检测命中（置信度 %.3f）", observation.confidence),
            category: .vision
        )
        return DocumentDetection(quad: quad, confidence: observation.confidence)
    }
}
