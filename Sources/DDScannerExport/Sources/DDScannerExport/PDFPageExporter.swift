// PDFPageExporter —— PDF 导出（占位，见 docs/architecture.md）。
import DDScannerCore
import Foundation

public struct PDFPageExporter: PageExporting {
    public init() {}

    public func export(page: ScannedPage, to url: URL) throws {
        AppLog.debug("导出页 \(page.identifier) → \(url.lastPathComponent)", category: .export)
        throw ScannerError.stageNotConfigured("PDFPageExporter")
    }
}
