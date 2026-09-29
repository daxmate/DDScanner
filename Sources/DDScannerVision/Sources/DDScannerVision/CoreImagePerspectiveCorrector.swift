// CoreImagePerspectiveCorrector —— 透视校正（占位，见 docs/architecture.md）。
// 后端落地时用 CIFilter.perspectiveCorrection 消费本层给出的单应矩阵。
import CoreImage
import DDScannerCore
import Foundation

public struct CoreImagePerspectiveCorrector: PerspectiveCorrecting {
    public init() {}

    public func homography(for quad: DocumentQuad) throws -> Homography {
        guard let homography = Homography(mapping: quad) else {
            throw ScannerError.homographyNotSolvable
        }
        AppLog.debug("透视校正矩阵求解完成", category: .vision)
        return homography
    }
}
