// ScannerError —— Core 层错误类型（占位，见 docs/architecture.md）。
import Foundation

public enum ScannerError: Error, Equatable, CustomStringConvertible {
    /// 给定帧上未找到文档边界。
    case documentNotFound
    /// 检测到的四边形退化（三点共线 / 面积为零）。
    case degenerateQuad
    /// 单应矩阵奇异，无法求解。
    case homographyNotSolvable
    /// 管线阶段未装配（组合根漏装配）。
    case stageNotConfigured(String)
    /// 输入帧尺寸非法。
    case invalidFrameSize(width: Int, height: Int)

    public var description: String {
        switch self {
        case .documentNotFound: return "未检测到文档边界"
        case .degenerateQuad: return "检测到的四边形退化"
        case .homographyNotSolvable: return "单应矩阵奇异"
        case let .stageNotConfigured(stage): return "管线阶段未装配：\(stage)"
        case let .invalidFrameSize(width, height): return "非法帧尺寸：\(width)×\(height)"
        }
    }
}
