// 契约：契约登记表自洽（docs/contract-register.md 必须逐条登记本目录契约测试）。
import Foundation
import Testing

@Suite("契约 · 登记表自洽")
struct ContractRegisterContractTests {
    private static let registerPath = "docs/contract-register.md"

    @Test("每份契约测试都在登记表里")
    func everyContractRegistered() {
        let document = RepoLayout.text(Self.registerPath)
        #expect(document.contains("契约登记表"), "登记表文档缺失或标题不符：\(Self.registerPath)")
        let contracts = RepoLayout
            .files(under: ["Tests/ContractTests"], extensions: ["swift"])
            .filter { $0.contains("ContractTests.swift") }
            .map { ($0 as NSString).lastPathComponent }
            .sorted()
        #expect(!contracts.isEmpty, "必须扫到契约测试文件，否则契约是空转")
        let missing = contracts.filter { !document.contains($0) }
        #expect(missing.isEmpty, "登记表缺少契约条目：\(missing)")
    }

    @Test("自证：漏登记的契约必须被抓到")
    func selfProofMissingEntry() {
        let document = "| NewThingContractTests.swift | 已登记 |"
        let contracts = ["NewThingContractTests.swift", "ForgottenContractTests.swift"]
        let missing = contracts.filter { !document.contains($0) }
        #expect(missing == ["ForgottenContractTests.swift"])
    }
}
