// swiftc 直编驱动：与 Tests/ContractTests/Support/StructuralBudgetRule.swift 一起编译。
// 用法：<bin> <repo-root> | <bin> --selftest
import Foundation

@main
struct StructuralBudgetTool {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--selftest") {
            runSelfTest()
            return
        }
        let root = URL(fileURLWithPath: arguments.first ?? FileManager.default.currentDirectoryPath)
        let whitelistPath = root.appendingPathComponent("Tests/Fixtures/structural-budget-whitelist.tsv")
        guard let tsv = try? String(contentsOf: whitelistPath, encoding: .utf8) else {
            fail("无法读取白名单：\(whitelistPath.path)")
        }
        let whitelist: StructuralBudgetWhitelist
        switch StructuralBudgetRule.parseWhitelist(tsv: tsv) {
        case let .success(parsed): whitelist = parsed
        case let .failure(message): fail("白名单解析失败（fail-closed）：\(message)")
        }
        let inputs = collectInputs(root: root)
        guard !inputs.isEmpty else { fail("未扫到任何 Swift 文件，契约空转") }
        let violations = StructuralBudgetRule.evaluate(inputs: inputs, whitelist: whitelist)
        guard violations.isEmpty else {
            fail("结构超限 \(violations.count) 处：\n" + violations.map { "  - \($0.description)" }.joined(separator: "\n"))
        }
        report("✅ 结构预算通过：\(inputs.count) 个 Swift 文件，单文件 ≤ \(StructuralBudgetRule.maximumFileLines) 行，产品代码无裸 print")
    }

    static func collectInputs(root: URL) -> [StructuralBudgetInput] {
        let roots = Array(Set(StructuralBudgetRule.lineCountRoots + StructuralBudgetRule.printRoots)).sorted()
        var inputs = [StructuralBudgetInput]()
        for relative in roots {
            let base = root.appendingPathComponent(relative)
            guard let enumerator = FileManager.default.enumerator(atPath: base.path) else { continue }
            for case let entry as String in enumerator {
                guard (entry as NSString).pathExtension == "swift" else { continue }
                let path = relative + "/" + entry
                guard !path.contains("/.build/") else { continue }
                let contents = (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
                inputs.append(StructuralBudgetInput(path: path, contents: contents))
            }
        }
        return inputs.sorted { $0.path < $1.path }
    }

    static func runSelfTest() {
        let longInput = StructuralBudgetInput(
            path: "Sources/DDScannerCore/Sources/DDScannerCore/TooLong.swift",
            contents: Array(repeating: "// 占位", count: StructuralBudgetRule.maximumFileLines + 1).joined(separator: "\n")
        )
        let longViolations = StructuralBudgetRule.evaluate(inputs: [longInput], whitelist: StructuralBudgetWhitelist(reasons: [:]))
        guard longViolations.map(\.kind) == [.fileTooLong] else { fail("自证失败：超长文件未被抓到") }
        let printInput = StructuralBudgetInput(
            path: "App/Leaky.swift",
            contents: "let m = " + "print" + "(\"x\")"
        )
        let printViolations = StructuralBudgetRule.evaluate(inputs: [printInput], whitelist: StructuralBudgetWhitelist(reasons: [:]))
        guard printViolations.map(\.kind) == [.barePrint] else { fail("自证失败：产品代码裸 print 未被抓到") }
        guard case .failure = StructuralBudgetRule.parseWhitelist(tsv: "Sources/Bad.swift") else {
            fail("自证失败：白名单缺理由列未被判失败")
        }
        report("✅ 自证通过：超长文件 / 裸 print / 白名单缺理由 三类注入均被判红")
    }

    static func report(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
