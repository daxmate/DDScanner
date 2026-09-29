// 测试替身（占位，见 docs/architecture.md）。
import Foundation
@testable import DDScannerCore

struct FixedDetector: DocumentDetecting {
    var quad: DocumentQuad
    func detectDocument(in frame: ScanFrame) throws -> DocumentQuad { quad }
}

struct FailingDetector: DocumentDetecting {
    func detectDocument(in frame: ScanFrame) throws -> DocumentQuad {
        throw ScannerError.documentNotFound
    }
}

struct IdentityCorrector: PerspectiveCorrecting {
    func homography(for quad: DocumentQuad) throws -> Homography {
        guard let homography = Homography(mapping: quad) else {
            throw ScannerError.homographyNotSolvable
        }
        return homography
    }
}

struct FixedDewarper: PageDewarping {
    var calls: Int = 0
    func samplingGrid(for frame: ScanFrame, quad: DocumentQuad, columns: Int, rows: Int) throws -> SampleGrid {
        GridSampler.bilinear(within: quad, columns: columns, rows: rows)
    }
}

final class RecordingExporter: PageExporting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var exported: [URL] = []

    func export(page: ScannedPage, to url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        exported.append(url)
    }
}

final class CapturingSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(line)
    }
}

extension DocumentQuad {
    /// 100×200 画布内的标准四边形。
    static var fixture: DocumentQuad {
        DocumentQuad(
            topLeft: CGPoint(x: 10, y: 20),
            topRight: CGPoint(x: 90, y: 20),
            bottomRight: CGPoint(x: 90, y: 180),
            bottomLeft: CGPoint(x: 10, y: 180)
        )
    }
}
