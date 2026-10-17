// ScanFileExporterTests —— 位图导出行为测试（本机 macOS 可跑，无模拟器）。
//
// 覆盖：JPEG/PDF 落盘与解码尺寸、PDF 单页尺寸（72 DPI 口径）、唯一目录不覆盖、非法目录抛错且不留半成品。
import CoreGraphics
import DDScannerCore
import DDScannerExport
import Foundation
import ImageIO
import Testing

@Suite("ScanFileExporter")
struct ScanFileExporterTests {
    /// 合成一张纯色位图（尺寸 120×160，非正方形，便于验证 PDF 尺寸与图片像素一致）。
    private func makeImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// 建一个独立的临时根目录。
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ddscanner-export-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func decodedPixelSize(of imageURL: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (image.width, image.height)
    }

    private func pdfPageCountAndSize(of url: URL) -> (count: Int, width: CGFloat, height: CGFloat)? {
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages >= 1 else { return nil }
        guard let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        return (document.numberOfPages, box.width, box.height)
    }

    @Test("导出后 JPEG 与 PDF 都存在，JPEG 解码尺寸正确")
    func exportsBothFilesWithCorrectJPEGSize() throws {
        let root = try makeRoot()
        let image = makeImage(width: 120, height: 160)
        let result = try ScanFileExporter().export(image: image, baseFilename: "page", to: root)

        #expect(FileManager.default.fileExists(atPath: result.imageURL.path))
        #expect(FileManager.default.fileExists(atPath: result.pdfURL.path))
        #expect(result.imageURL.pathExtension == "jpg")
        #expect(result.pdfURL.pathExtension == "pdf")

        let size = try #require(decodedPixelSize(of: result.imageURL))
        #expect(size.width == 120)
        #expect(size.height == 160)
    }

    @Test("PDF 为 1 页，页面尺寸与图片按 72 DPI 换算一致")
    func pdfIsSinglePageWithMatchingSize() throws {
        let root = try makeRoot()
        let image = makeImage(width: 120, height: 160)
        let result = try ScanFileExporter().export(image: image, baseFilename: "page", to: root)

        let pdf = try #require(pdfPageCountAndSize(of: result.pdfURL))
        #expect(pdf.count == 1)
        #expect(pdf.width == 120)
        #expect(pdf.height == 160)
    }

    @Test("非正方形图：PDF 页面宽高各自与像素一致")
    func pdfSizeMatchesNonSquareImage() throws {
        let root = try makeRoot()
        let image = makeImage(width: 200, height: 80)
        let result = try ScanFileExporter().export(image: image, baseFilename: "page", to: root)

        let pdf = try #require(pdfPageCountAndSize(of: result.pdfURL))
        #expect(pdf.count == 1)
        #expect(pdf.width == 200)
        #expect(pdf.height == 80)
    }

    @Test("两次导出到同一根目录 → 两个不同子目录、文件不覆盖")
    func exportsToDistinctDirectories() throws {
        let root = try makeRoot()
        let image = makeImage(width: 120, height: 160)
        let first = try ScanFileExporter().export(image: image, baseFilename: "page", to: root)
        let second = try ScanFileExporter().export(image: image, baseFilename: "page", to: root)

        #expect(first.directoryURL != second.directoryURL)
        #expect(FileManager.default.fileExists(atPath: first.imageURL.path))
        #expect(FileManager.default.fileExists(atPath: second.imageURL.path))
        #expect(first.imageURL.path != second.imageURL.path)
    }

    @Test("目标根目录不可创建 → 抛 exportFailed 且不留半成品")
    func throwsWhenRootUncreatable() throws {
        // 用一个指向普通文件的路径当根目录：createDirectory 必然失败。
        let fileRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ddscanner-export-file-\(UUID().uuidString)")
        try Data([0x00]).write(to: fileRoot)
        let image = makeImage(width: 120, height: 160)
        let exporter = ScanFileExporter()

        do {
            _ = try exporter.export(image: image, baseFilename: "page", to: fileRoot)
            Issue.record("根目录不可创建时应当抛错")
        } catch let error as ScannerError {
            guard case .exportFailed = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
            // 不留下半成品：文件根目录里不该多出任何子目录。
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: fileRoot.path)) ?? []
            #expect(entries.isEmpty, "失败后不应留下半成品：\(entries)")
        }
    }
}
