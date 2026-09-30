// AppCompositionRoot —— 全应用唯一装配点（见 docs/architecture.md）。
// 视图层一律从 Environment 取依赖；除 Preview 外，任何新装配点都必须先改本文件。
import DDScannerCore
import DDScannerDewarp
import DDScannerExport
import DDScannerVision
import SwiftUI

/// 视图层可消费的依赖集合。
struct ScanEnvironment {
    let pipeline: ScanPipeline
    /// 像素型文档检测（Vision 段分割 + 矩形回退）；检测不到时抛 `documentNotFound`。
    let imageDetector: ImageDocumentDetecting
    /// 透视校正 + 裁切的平台成像后端（几何在 Core）。
    let perspectiveCorrector: CoreImagePerspectiveCorrector
    /// 去畸变网格后端（UVDoc Core ML）；**模型缺失时为 nil**，消费端必须能降级处理、不得崩。
    let gridPredictor: GridPredicting?
    /// 模型装载结果的人话描述，供开发自测页显示（成功或失败原因）。
    let dewarpStatus: String
    /// 请求的算力单元（MLComputeUnits）；模型不可用时为「不可用」。
    let dewarpComputeUnits: String
}

enum AppCompositionRoot {
    /// 唯一装配点：后端在此选择，视图层不得自行 new 任何实现。
    static func makeScanEnvironment() -> ScanEnvironment {
        let detector = VisionDocumentDetector()
        let corrector = CoreImagePerspectiveCorrector()
        let pipeline = ScanPipeline(
            detector: detector,
            corrector: corrector,
            dewarp: nil,
            exporter: PDFPageExporter()
        )
        let (gridPredictor, dewarpStatus, dewarpComputeUnits) = makeDewarpBackend()
        AppLog.info("扫描管线装配完成（去畸变：\(dewarpStatus)）", category: .app)
        return ScanEnvironment(
            pipeline: pipeline,
            imageDetector: detector,
            perspectiveCorrector: corrector,
            gridPredictor: gridPredictor,
            dewarpStatus: dewarpStatus,
            dewarpComputeUnits: dewarpComputeUnits
        )
    }

    /// 装载去畸变模型；**失败只降级不崩**：模型缺失/加载失败 → `nil` + 原因文本。
    private static func makeDewarpBackend() -> (GridPredicting?, String, String) {
        let descriptor = DewarpModelDescriptor.uvDoc
        do {
            let backend = try CoreMLDewarpBackend(descriptor: descriptor)
            let units = "\(backend.computeUnits)"
            return (backend, "已装载 \(descriptor.bundleResource)（computeUnits=\(units)）", units)
        } catch {
            AppLog.warning("去畸变模型不可用，已降级为无去畸变：\(error)", category: .dewarp)
            return (nil, "模型不可用：\(error)", "不可用")
        }
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
