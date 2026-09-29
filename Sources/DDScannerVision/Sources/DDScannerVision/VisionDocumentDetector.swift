// VisionDocumentDetector —— Vision 边缘检测（占位，见 docs/architecture.md）。
import DDScannerCore
import Foundation
import Vision

/// Apple 原生文档边界检测；具体像素管线在业务批接入（本批只留可编译占位）。
public struct VisionDocumentDetector: DocumentDetecting {
    public init() {}

    public func detectDocument(in frame: ScanFrame) throws -> DocumentQuad {
        let request = VNDetectDocumentSegmentationRequest()
        AppLog.debug("Vision 请求 revision=\(request.revision)", category: .vision)
        throw ScannerError.stageNotConfigured("VisionDocumentDetector")
    }
}
