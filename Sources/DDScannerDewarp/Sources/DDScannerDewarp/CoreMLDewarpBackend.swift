// CoreMLDewarpBackend —— Core ML 去畸变后端（占位，见 docs/model-supply-chain.md）。
// 协议与实现分离：模型未随仓库分发前，后端一律显式失败，不回落到静默降级。
import CoreML
import DDScannerCore
import Foundation

public struct CoreMLDewarpBackend: PageDewarping {
    public let descriptor: DewarpModelDescriptor

    public init(descriptor: DewarpModelDescriptor = .uvDoc) {
        self.descriptor = descriptor
    }

    public func samplingGrid(
        for frame: ScanFrame,
        quad: DocumentQuad,
        columns: Int,
        rows: Int
    ) throws -> SampleGrid {
        AppLog.debug("请求模型 \(descriptor.name)@\(descriptor.version)", category: .dewarp)
        throw ScannerError.stageNotConfigured("CoreMLDewarpBackend")
    }
}
