// ScanFileExporter —— 位图导出器（批 B3）：把矫正后的 CGImage 一次性写成 JPEG + 单页 PDF，
// 落到沙盒 Documents/Scans 下的唯一子目录。见 docs/architecture.md 与 docs/contract-register.md。
//
// 与旧 PageExporting（采样网格契约）的关系：本类型以**像素 CGImage** 为输入，是 v1 位图导出
// 的唯一实现；旧 PageExporting / ScannedPage 保留给未来管线，本批不接线（见契约登记表）。
// 类型无全局状态、Sendable，可在后台线程使用（调用方用 Task.detached）。
import CoreGraphics
import DDScannerCore
import Foundation
import ImageIO

/// 一次位图导出的落盘结果。
public struct ScanExportResult: Sendable, Equatable {
    /// JPEG 文件 URL。
    public let imageURL: URL
    /// 单页 PDF 文件 URL。
    public let pdfURL: URL
    /// 本次导出所在的唯一目录 URL。
    public let directoryURL: URL

    public init(imageURL: URL, pdfURL: URL, directoryURL: URL) {
        self.imageURL = imageURL
        self.pdfURL = pdfURL
        self.directoryURL = directoryURL
    }
}

/// 以矫正后位图为输入的导出器：写 JPEG（ImageIO）+ 单页 PDF（CoreGraphics），绝不覆盖已有文件。
public struct ScanFileExporter: Sendable {
    /// JPEG 压缩质量（0…1，约 0.92 兼顾体积与清晰度）。
    private static let jpegQuality: CGFloat = 0.92

    public init() {}

    /// 把一张矫正后的页面导出为 JPEG + 单页 PDF。
    /// - Parameters:
    ///   - image: 矫正后的位图（像素尺寸决定 PDF 页面尺寸：按 72 DPI 换算成 points）。
    ///   - baseFilename: 文件名主干（不含扩展名），如 "page"。
    ///   - rootDirectory: 导出根目录（App 传沙盒 Documents/Scans）。
    /// - Returns: 落盘结果（imageURL / pdfURL / directoryURL）。
    /// - Throws: 目录不可写、创建失败或编码失败时抛 ScannerError.exportFailed；失败时不留下半成品。
    public func export(image: CGImage, baseFilename: String, to rootDirectory: URL) throws -> ScanExportResult {
        let directory = try makeUniqueDirectory(inside: rootDirectory)

        // 先写临时文件，两份都成功后再原子搬进目标目录；任一步失败则清理临时产物，目录里不留半成品。
        let fileName = sanitizedBaseFilename(baseFilename)
        let temporaryImage = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jpg")
        let temporaryPDF = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".pdf")
        defer {
            try? FileManager.default.removeItem(at: temporaryImage)
            try? FileManager.default.removeItem(at: temporaryPDF)
        }

        do {
            try writeJPEG(image: image, to: temporaryImage)
            try writePDF(image: image, to: temporaryPDF)
        } catch {
            // 目录已建但内容写失败：回收这个空目录，不留半成品。
            try? FileManager.default.removeItem(at: directory)
            throw error
        }

        let finalImageURL = try uniqueFileURL(directory: directory, filename: fileName, extension: "jpg")
        let finalPDFURL = try uniqueFileURL(directory: directory, filename: fileName, extension: "pdf")
        do {
            try FileManager.default.moveItem(at: temporaryImage, to: finalImageURL)
            try FileManager.default.moveItem(at: temporaryPDF, to: finalPDFURL)
        } catch {
            try? FileManager.default.removeItem(at: finalImageURL)
            try? FileManager.default.removeItem(at: finalPDFURL)
            try? FileManager.default.removeItem(at: directory)
            throw ScannerError.exportFailed("写入导出文件失败：\(error.localizedDescription)")
        }

        AppLog.info(
            "已导出 \(image.width)×\(image.height) → \(finalImageURL.lastPathComponent) + \(finalPDFURL.lastPathComponent)",
            category: .export
        )
        return ScanExportResult(imageURL: finalImageURL, pdfURL: finalPDFURL, directoryURL: directory)
    }

    // MARK: - 目录与文件命名

    /// 在根目录下创建唯一子目录：<时间戳>-<短随机 id>，重名则换 id 重试，绝不覆盖已有目录。
    private func makeUniqueDirectory(inside rootDirectory: URL) throws -> URL {
        guard rootDirectory.isFileURL, !rootDirectory.path.isEmpty else {
            throw ScannerError.exportFailed("导出根目录非法：\(rootDirectory.path)")
        }
        do {
            try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        } catch {
            throw ScannerError.exportFailed("无法创建导出根目录：\(error.localizedDescription)")
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        for _ in 0 ..< 8 {
            let shortID = String(UUID().uuidString.prefix(4)).lowercased()
            let candidate = rootDirectory.appendingPathComponent("\(stamp)-\(shortID)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
                return candidate
            } catch {
                // 目录已存在（极端撞名）→ 换 id 重试；其它错误直接抛。
                if (error as NSError).domain == NSCocoaErrorDomain,
                   (error as NSError).code == NSFileWriteFileExistsError {
                    continue
                }
                throw ScannerError.exportFailed("无法创建导出目录：\(error.localizedDescription)")
            }
        }
        throw ScannerError.exportFailed("无法生成唯一的导出目录")
    }

    /// 生成不覆盖已有文件的最终 URL：同名则追加 -2 / -3 … 后缀。
    private func uniqueFileURL(directory: URL, filename: String, extension ext: String) throws -> URL {
        let base = directory.appendingPathComponent(filename).appendingPathExtension(ext)
        guard FileManager.default.fileExists(atPath: base.path) else { return base }
        var index = 2
        while index <= 1000 {
            let candidate = directory
                .appendingPathComponent("\(filename)-\(index)")
                .appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
        throw ScannerError.exportFailed("同名文件过多，无法生成不冲突的文件名")
    }

    private func sanitizedBaseFilename(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "page" }
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let filtered = trimmed.components(separatedBy: invalid).joined()
        return filtered.isEmpty ? "page" : filtered
    }

    // MARK: - 写 JPEG / PDF

    /// 用 ImageIO 写 JPEG（质量约 0.92）。
    private func writeJPEG(image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw ScannerError.exportFailed("无法创建 JPEG 输出目标")
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: Self.jpegQuality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ScannerError.exportFailed("JPEG 编码失败")
        }
    }

    /// 用 CoreGraphics 写单页 PDF：页面尺寸 = 图片像素按 72 DPI 换算成 points，图片铺满页面、保持纵横比。
    private func writePDF(image: CGImage, to url: URL) throws {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        var mediaBox = CGRect(x: 0, y: 0, width: width, height: height)
        let metadata = [kCGPDFContextTitle as String: "Scanned Page"] as CFDictionary
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, metadata) else {
            throw ScannerError.exportFailed("无法创建 PDF 输出目标")
        }
        context.beginPDFPage(nil)
        // Core Graphics 位图坐标原点在左上、PDF 在左下：按 y 轴翻转绘制，保持图像不颠倒。
        context.saveGState()
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.restoreGState()
        context.endPDFPage()
        context.closePDF()
    }
}
