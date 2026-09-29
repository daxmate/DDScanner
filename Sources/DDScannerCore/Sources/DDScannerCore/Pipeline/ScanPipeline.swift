// ScanPipeline —— 管线编排（占位，见 docs/architecture.md）。
// 只做编排与错误收敛，不含任何平台 API。
import CoreGraphics
import Foundation

/// 扫描管线：检测 → 透视校正 → 去畸变（可选）→ 导出（可选）。
public struct ScanPipeline: Sendable {
    public var detector: DocumentDetecting
    public var corrector: PerspectiveCorrecting
    public var dewarp: PageDewarping?
    public var exporter: PageExporting?
    public var gridColumns: Int
    public var gridRows: Int

    public init(
        detector: DocumentDetecting,
        corrector: PerspectiveCorrecting,
        dewarp: PageDewarping? = nil,
        exporter: PageExporting? = nil,
        gridColumns: Int = 64,
        gridRows: Int = 64
    ) {
        self.detector = detector
        self.corrector = corrector
        self.dewarp = dewarp
        self.exporter = exporter
        self.gridColumns = gridColumns
        self.gridRows = gridRows
    }

    /// 处理一帧；导出仅在传入 `destination` 且已装配 exporter 时发生。
    public func process(_ frame: ScanFrame, destination: URL? = nil) throws -> ScannedPage {
        guard frame.isValid else {
            throw ScannerError.invalidFrameSize(width: frame.width, height: frame.height)
        }
        let quad = try detector.detectDocument(in: frame)
        guard !quad.isDegenerate else { throw ScannerError.degenerateQuad }
        let homography = try corrector.homography(for: quad)
        AppLog.debug("已求解单应矩阵", category: .pipeline)
        let grid = try makeGrid(frame: frame, quad: quad, homography: homography)
        let page = ScannedPage(identifier: frame.identifier, quad: quad, samplingGrid: grid)
        if let destination {
            guard let exporter else { throw ScannerError.stageNotConfigured("exporter") }
            try exporter.export(page: page, to: destination)
        }
        return page
    }

    private func makeGrid(frame: ScanFrame, quad: DocumentQuad, homography: Homography) throws -> SampleGrid {
        if let dewarp {
            return try dewarp.samplingGrid(
                for: frame,
                quad: quad,
                columns: gridColumns,
                rows: gridRows
            )
        }
        AppLog.debug("未装配去畸变后端，回落平面双线性网格", category: .pipeline)
        return GridSampler.bilinear(within: quad, columns: gridColumns, rows: gridRows)
    }
}
