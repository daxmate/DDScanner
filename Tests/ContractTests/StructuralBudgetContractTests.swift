// 契约：结构硬上限（G2/G3/G4）。白名单见 Tests/Fixtures/structural-budget-whitelist.tsv。
import Foundation
import Testing

@Suite("契约 · 结构硬上限")
struct StructuralBudgetContractTests {
    private static let whitelistPath = "Tests/Fixtures/structural-budget-whitelist.tsv"

    private func loadedWhitelist() throws -> StructuralBudgetWhitelist {
        let tsv = RepoLayout.text(Self.whitelistPath)
        #expect(!tsv.isEmpty, "白名单文件必须存在且非空")
        switch StructuralBudgetRule.parseWhitelist(tsv: tsv) {
        case let .success(whitelist): return whitelist
        case let .failure(message): throw ContractFailure(message)
        }
    }

    @Test("仓库当前无结构超限")
    func repositoryIsClean() throws {
        let whitelist = try loadedWhitelist()
        let inputs = RepoLayout.readInputs(
            under: StructuralBudgetRule.lineCountRoots + StructuralBudgetRule.printRoots,
            extensions: ["swift"]
        )
        #expect(!inputs.isEmpty, "必须真的扫到 Swift 文件，否则契约是空转")
        let violations = StructuralBudgetRule.evaluate(inputs: inputs, whitelist: whitelist)
        #expect(violations.isEmpty, "结构超限：\(violations.map(\.description).joined(separator: "; "))")
    }

    @Test("自证：>600 行文件必须被抓到")
    func selfProofLongFile() {
        let longFile = StructuralBudgetInput(
            path: "Sources/DDScannerCore/Sources/DDScannerCore/TooLong.swift",
            contents: Array(repeating: "// 占位", count: 601).joined(separator: "\n")
        )
        let violations = StructuralBudgetRule.evaluate(inputs: [longFile], whitelist: StructuralBudgetWhitelist(reasons: [:]))
        #expect(violations.map(\.kind) == [.fileTooLong])
    }

    @Test("自证：产品代码裸 print 必须被抓到")
    func selfProofBarePrint() {
        // 运行时内容含裸 print 调用；源码分片拼接，避免本文件自身被扫到。
        let marker = "print" + "(\"x\")"
        let printing = StructuralBudgetInput(path: "App/Leaky.swift", contents: "let m = " + marker)
        let violations = StructuralBudgetRule.evaluate(inputs: [printing], whitelist: StructuralBudgetWhitelist(reasons: [:]))
        #expect(violations.map(\.kind) == [.barePrint])
    }

    @Test("自证：白名单缺理由必须失败（fail-closed）")
    func selfProofWhitelistWithoutReason() {
        let outcome = StructuralBudgetRule.parseWhitelist(tsv: "Sources/Bad.swift")
        guard case let .failure(message) = outcome else {
            Issue.record("缺理由列时应当解析失败")
            return
        }
        #expect(message.contains("理由"))
    }

    @Test("自证：白名单命中的路径不再报违规")
    func selfProofWhitelistSuppresses() throws {
        let outcome = StructuralBudgetRule.parseWhitelist(tsv: "Sources/A.swift\t历史遗留，见 issue #1")
        guard case let .success(whitelist) = outcome else {
            Issue.record("带理由的白名单应当解析成功")
            return
        }
        let longFile = StructuralBudgetInput(
            path: "Sources/A.swift",
            contents: Array(repeating: "// x", count: 700).joined(separator: "\n")
        )
        #expect(StructuralBudgetRule.evaluate(inputs: [longFile], whitelist: whitelist).isEmpty)
    }
}

/// 契约失败（用于在测试里中断并让 CI 报红）。
struct ContractFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
