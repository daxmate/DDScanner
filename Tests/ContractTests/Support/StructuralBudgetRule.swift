// StructuralBudgetRule —— 结构硬上限规则（可 `swiftc` 直编，不 import 测试框架）。
// 语义：① 单 Swift 文件行数 > 600 即违规；② 产品代码（Sources/、App/）出现裸 `print(` 即违规。
// 无棘轮、无基线计数：DDScanner 从零起步，存量永为 0（见 docs/architecture.md）。
import Foundation

struct StructuralBudgetInput: Equatable {
    let path: String
    let contents: String
}

struct StructuralBudgetViolation: Equatable, CustomStringConvertible {
    enum Kind: String {
        case fileTooLong = "file-too-long"
        case barePrint = "bare-print"
    }

    let path: String
    let kind: Kind
    let detail: String

    var description: String { "\(kind.rawValue) \(path) —— \(detail)" }
}

struct StructuralBudgetWhitelist: Equatable {
    /// 路径 → 理由（理由为空 = 解析失败，fail-closed）。
    let reasons: [String: String]

    func reason(for path: String) -> String? { reasons[path] }
}

/// 白名单解析结果（用枚举而非 Result，避免依赖 Error 的具体类型）。
enum StructuralBudgetWhitelistParseOutcome: Equatable {
    case success(StructuralBudgetWhitelist)
    case failure(String)
}

enum StructuralBudgetRule {
    static let maximumFileLines = 600
    static let lineCountRoots = ["Sources", "App", "Tests", "scripts"]
    static let printRoots = ["Sources", "App"]
    /// 日志出口允许列表：本仓日志模块也不使用 `print(`，故为空。
    static let printAllowedPaths: Set<String> = []

    /// 解析白名单 TSV：`#` 开头为注释；每条必须为 `path<TAB>reason`。任何一条缺理由 → 整体失败。
    static func parseWhitelist(tsv: String) -> StructuralBudgetWhitelistParseOutcome {
        var reasons = [String: String]()
        for (index, rawLine) in tsv.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let columns = rawLine.components(separatedBy: "\t")
            guard columns.count >= 2 else {
                return .failure("第 \(index + 1) 行缺少理由列（必须是 path<TAB>reason）")
            }
            let path = columns[0].trimmingCharacters(in: .whitespaces)
            let reason = columns[1].trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty, !reason.isEmpty else {
                return .failure("第 \(index + 1) 行路径或理由为空（fail-closed）")
            }
            reasons[path] = reason
        }
        return .success(StructuralBudgetWhitelist(reasons: reasons))
    }

    static func evaluate(
        inputs: [StructuralBudgetInput],
        whitelist: StructuralBudgetWhitelist
    ) -> [StructuralBudgetViolation] {
        var violations = [StructuralBudgetViolation]()
        for input in inputs where whitelist.reason(for: input.path) == nil {
            violations.append(contentsOf: checkLineCount(input))
            violations.append(contentsOf: checkBarePrint(input))
        }
        return violations
    }

    static func checkLineCount(_ input: StructuralBudgetInput) -> [StructuralBudgetViolation] {
        guard lineCountRoots.contains(where: { input.path.hasPrefix($0 + "/") }) else { return [] }
        let lines = input.contents.components(separatedBy: .newlines).count
        guard lines > maximumFileLines else { return [] }
        return [StructuralBudgetViolation(
            path: input.path,
            kind: .fileTooLong,
            detail: "\(lines) 行 > 上限 \(maximumFileLines) 行"
        )]
    }

    static func checkBarePrint(_ input: StructuralBudgetInput) -> [StructuralBudgetViolation] {
        guard printRoots.contains(where: { input.path.hasPrefix($0 + "/") }),
              !printAllowedPaths.contains(input.path) else { return [] }
        let marker = "print" + "("
        let hits = input.contents.components(separatedBy: .newlines).enumerated().filter { $0.element.contains(marker) }
        return hits.map { index, _ in
            StructuralBudgetViolation(path: input.path, kind: .barePrint, detail: "第 \(index + 1) 行出现裸 print")
        }
    }
}
