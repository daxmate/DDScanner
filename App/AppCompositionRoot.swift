// AppCompositionRoot —— 全应用唯一装配点（占位，见 docs/architecture.md）。
// 视图层一律从 Environment 取依赖；除 Preview 外，任何新装配点都必须先改本文件。
import DDScannerCore
import DDScannerDewarp
import DDScannerExport
import DDScannerVision
import SwiftUI

/// 视图层可消费的依赖集合。
struct ScanEnvironment {
    let pipeline: ScanPipeline
}

enum AppCompositionRoot {
    /// 唯一装配点：后端在此选择，视图层不得自行 new 任何实现。
    static func makeScanEnvironment() -> ScanEnvironment {
        let pipeline = ScanPipeline(
            detector: VisionDocumentDetector(),
            corrector: CoreImagePerspectiveCorrector(),
            dewarp: nil,
            exporter: PDFPageExporter()
        )
        AppLog.info("扫描管线装配完成", category: .app)
        return ScanEnvironment(pipeline: pipeline)
    }
}

private struct ScanEnvironmentKey: EnvironmentKey {
    static let defaultValue: ScanEnvironment? = nil
}

extension EnvironmentValues {
    var scanEnvironment: ScanEnvironment? {
        get { self[ScanEnvironmentKey.self] }
        set { self[ScanEnvironmentKey.self] = newValue }
    }
}
