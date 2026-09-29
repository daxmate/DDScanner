// 契约：组合根唯一装配点（G5），断言从消费端派生。
// ① 构造 ScanEnvironment 的文件必须唯一且是 App/AppCompositionRoot.swift；
// ② 每个消费端（@Environment(\.scanEnvironment)）必须在 Tests/Fixtures/environment-consumers.tsv 登记。
import Foundation
import Testing

@Suite("契约 · 组合根唯一装配点")
struct EnvironmentInjectionContractTests {
    private static let compositionRoot = "App/AppCompositionRoot.swift"
    private static let consumersFixture = "Tests/Fixtures/environment-consumers.tsv"

    private static func appSources() -> [StructuralBudgetInput] {
        RepoLayout.readInputs(under: ["App"], extensions: ["swift"])
    }

    @Test("装配点唯一且落在组合根")
    func singleAssemblySite() {
        let sources = Self.appSources()
        #expect(!sources.isEmpty, "必须扫到 App 源码，否则契约是空转")
        let assemblySites = AssemblyScan.sites(in: sources)
        #expect(assemblySites == [Self.compositionRoot], "装配点必须唯一：\(assemblySites)")
    }

    @Test("消费端必须登记（fail-closed）")
    func consumersRegistered() throws {
        let registered = try registeredConsumers()
        let sources = Self.appSources()
        let consumers = sources.filter { $0.contents.contains("@Environment(\\.scanEnvironment)") }.map(\.path).sorted()
        #expect(!consumers.isEmpty, "必须至少有一个消费端，否则契约是空转")
        for consumer in consumers {
            #expect(registered.contains(consumer), "消费端未登记：\(consumer)")
        }
    }

    @Test("自证：出现第二个装配点必须被抓到")
    func selfProofSecondAssemblySite() {
        let sources = [
            StructuralBudgetInput(path: Self.compositionRoot, contents: "let env = ScanEnvironment(pipeline: p)"),
            StructuralBudgetInput(path: "App/Rogue.swift", contents: "let env = ScanEnvironment(pipeline: p)"),
        ]
        #expect(AssemblyScan.sites(in: sources).count == 2)
    }

    @Test("自证：工厂方法名不算装配点（避免误报）")
    func selfProofFactoryCallIsNotASite() {
        let sources = [
            StructuralBudgetInput(path: "App/DDScannerApp.swift", contents: "AppCompositionRoot.makeScanEnvironment()"),
            StructuralBudgetInput(path: Self.compositionRoot, contents: "return ScanEnvironment(pipeline: pipeline)"),
        ]
        #expect(AssemblyScan.sites(in: sources) == [Self.compositionRoot])
    }

    @Test("自证：未登记消费端必须被抓到")
    func selfProofUnregisteredConsumer() {
        let sources = [
            StructuralBudgetInput(path: "App/NewView.swift", contents: "@Environment(\\.scanEnvironment) var env"),
        ]
        let registered: Set<String> = []
        let unregistered = sources
            .filter { $0.contents.contains("@Environment(\\.scanEnvironment)") }
            .map(\.path)
            .filter { !registered.contains($0) }
        #expect(unregistered == ["App/NewView.swift"])
    }

    @Test("自证：登记表缺理由列必须失败（fail-closed）")
    func selfProofFixtureWithoutReason() {
        guard case .failure = StructuralBudgetRule.parseWhitelist(tsv: "App/ContentView.swift") else {
            Issue.record("缺理由列必须解析失败")
            return
        }
    }

    private func registeredConsumers() throws -> Set<String> {
        let tsv = RepoLayout.text(Self.consumersFixture)
        #expect(!tsv.isEmpty, "登记表必须存在且非空")
        switch StructuralBudgetRule.parseWhitelist(tsv: tsv) {
        case let .success(whitelist): return Set(whitelist.reasons.keys)
        case let .failure(message): throw ContractFailure(message)
        }
    }
}

/// 装配点扫描：`ScanEnvironment(` 且前一个字符不是标识符字符（避免命中 `makeScanEnvironment(`）。
enum AssemblyScan {
    static let typeName = "ScanEnvironment"

    static func sites(in sources: [StructuralBudgetInput]) -> [String] {
        sources.filter { containsConstruction($0.contents) }.map(\.path).sorted()
    }

    static func containsConstruction(_ text: String) -> Bool {
        let needle = typeName + "("
        var remainder = Substring(text)
        while let range = remainder.range(of: needle) {
            let preceding = remainder[remainder.startIndex ..< range.lowerBound].last
            if preceding == nil || !isIdentifierCharacter(preceding!) {
                return true
            }
            remainder = remainder[range.upperBound...]
        }
        return false
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
