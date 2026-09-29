// ScanStage —— 管线阶段协议与输入/输出值类型（占位，见 docs/architecture.md）。
// 协议与实现分离：Core 只声明契约，Apple / Core ML 后端在各自模块实现。
import CoreGraphics
import Foundation

/// 一帧待处理的输入画面描述（不含具体像素类型，保持平台无关）。
public struct ScanFrame: Equatable, Sendable {
    public let identifier: String
    public let width: Int
    public let height: Int

    public init(identifier: String, width: Int, height: Int) {
        self.identifier = identifier
        self.width = width
        self.height = height
    }

    public var size: CGSize { CGSize(width: width, height: height) }

    public var isValid: Bool { width > 0 && height > 0 }
}

/// 边缘检测：输入帧 → 文档四角。
public protocol DocumentDetecting: Sendable {
    func detectDocument(in frame: ScanFrame) throws -> DocumentQuad
}

/// 透视校正：四角 → 单应矩阵。
public protocol PerspectiveCorrecting: Sendable {
    func homography(for quad: DocumentQuad) throws -> Homography
}

/// 非线性去畸变：输入帧 + 四角 → 采样网格（后端可为 Core ML 模型）。
public protocol PageDewarping: Sendable {
    func samplingGrid(for frame: ScanFrame, quad: DocumentQuad, columns: Int, rows: Int) throws -> SampleGrid
}

/// 导出：采样结果 → 目标文件（PDF / 图片由 DDScannerExport 实现）。
public protocol PageExporting: Sendable {
    func export(page: ScannedPage, to url: URL) throws
}

/// 一页已完成几何处理的扫描结果。
public struct ScannedPage: Equatable, Sendable {
    public let identifier: String
    public let quad: DocumentQuad
    public let samplingGrid: SampleGrid

    public init(identifier: String, quad: DocumentQuad, samplingGrid: SampleGrid) {
        self.identifier = identifier
        self.quad = quad
        self.samplingGrid = samplingGrid
    }
}
