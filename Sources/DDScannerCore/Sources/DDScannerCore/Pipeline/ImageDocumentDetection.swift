// ImageDocumentDetecting —— 像素型文档检测契约（Core 只声明协议，实现见 DDScannerVision）。
//
// 为何与 `DocumentDetecting` 分开：`ScanFrame` 只带帧几何（不含像素），平台后端（Vision）需要真实
// 像素才能出四角。两个入口分工明确——`DocumentDetecting` 是「帧几何 → 四角」的管线阶段契约，
// 本协议是「像素 → 四角 + 置信度」的检测契约。
import CoreGraphics
import Foundation

/// 一次文档检测的结果。
///
/// 坐标约定（**写死，消费端依赖**）：`quad` 为归一化坐标 ∈ [0,1]，原点在**图像左上角**、y 轴
/// **向下**，四角顺序 **左上 → 右上 → 右下 → 左下**（与 `DocumentQuad` 一致）。
public struct DocumentDetection: Equatable, Sendable {
    public let quad: DocumentQuad
    /// 检测置信度 ∈ [0,1]（后端未提供时为 0）。
    public let confidence: Float

    public init(quad: DocumentQuad, confidence: Float) {
        self.quad = quad
        self.confidence = confidence
    }
}

/// 像素型边缘检测：输入位图 → 文档四角 + 置信度；检测不到抛 `ScannerError.documentNotFound`。
public protocol ImageDocumentDetecting: Sendable {
    func detectDocument(in image: CGImage) throws -> DocumentDetection
}
