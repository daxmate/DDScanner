// 契约：多语 key 集合一致性（G6）。任一 .lproj 缺键/多键即红。
import Foundation
import Testing

@Suite("契约 · l10n key 集合")
struct LocalizationKeySetContractTests {
    private static let locales = ["zh-Hans", "en"]

    private func keys(of template: String) throws -> [String] {
        switch LocalizableStringsParser.keys(in: template) {
        case let .success(keys): return keys
        case let .failure(message): throw ContractFailure(message)
        }
    }

    @Test("各语种 key 集合完全一致")
    func keySetsMatch() throws {
        var table = [String: [String]]()
        for locale in Self.locales {
            let path = "Resources/\(locale).lproj/Localizable.strings"
            #expect(RepoLayout.exists(path), "缺少语种资源：\(path)")
            table[locale] = try keys(of: RepoLayout.text(path))
        }
        let reference = try #require(table[Self.locales[0]])
        #expect(!reference.isEmpty, "key 集合不能为空，否则契约是空转")
        for locale in Self.locales.dropFirst() {
            let current = try #require(table[locale])
            let missing = Set(reference).subtracting(current).sorted()
            let extra = Set(current).subtracting(reference).sorted()
            #expect(missing.isEmpty, "\(locale) 缺少 key：\(missing)")
            #expect(extra.isEmpty, "\(locale) 多出 key：\(extra)")
        }
    }

    @Test("消费端引用的 key 必须在资源里存在")
    func consumedKeysExist() throws {
        let reference = try keys(of: RepoLayout.text("Resources/\(Self.locales[0]).lproj/Localizable.strings"))
        var referenced = Set<String>()
        for path in RepoLayout.files(under: ["App"], extensions: ["swift"]) {
            let contents = RepoLayout.text(path)
            for key in LocalizableStringsParser.referencedKeys(inSource: contents) {
                referenced.insert(key)
            }
        }
        let unknown = referenced.subtracting(reference).sorted()
        #expect(unknown.isEmpty, "代码引用了未登记的 key：\(unknown)")
    }

    @Test("自证：缺键必须被抓到")
    func selfProofMissingKey() {
        let left = "\"a\" = \"A\";\n\"b\" = \"B\";"
        let right = "\"a\" = \"A\";"
        guard case let .success(leftKeys) = LocalizableStringsParser.keys(in: left),
              case let .success(rightKeys) = LocalizableStringsParser.keys(in: right) else {
            Issue.record("解析应当成功")
            return
        }
        #expect(Set(leftKeys).subtracting(rightKeys) == ["b"])
    }

    @Test("自证：格式坏行必须解析失败（fail-closed）")
    func selfProofMalformed() {
        guard case .failure = LocalizableStringsParser.keys(in: "\"a\" = \"A\"\n") else {
            Issue.record("缺少分号的条目必须解析失败")
            return
        }
    }
}

/// .strings 解析：只认 `"key" = "value";`，其它非注释行一律判为格式错误（fail-closed）。
enum LocalizableStringsParser {
    static func keys(in template: String) -> StringListParseOutcome {
        var keys = [String]()
        for (index, rawLine) in template.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("/*") || line.hasPrefix("//") { continue }
            guard line.hasSuffix(";"), line.contains("=") else {
                return .failure("第 \(index + 1) 行不是合法的 .strings 条目：\(line)")
            }
            let head = line.split(separator: "=", maxSplits: 1)[0].trimmingCharacters(in: .whitespaces)
            guard head.hasPrefix("\""), head.hasSuffix("\""), head.count > 2 else {
                return .failure("第 \(index + 1) 行 key 不是合法字符串：\(head)")
            }
            keys.append(String(head.dropFirst().dropLast()))
        }
        return .success(keys)
    }

    /// 从 Swift 源码里抽取 `String(localized: "key")` 形式的消费点。
    static func referencedKeys(inSource source: String) -> [String] {
        var keys = [String]()
        let marker = "String(localized: \""
        var remainder = Substring(source)
        while let range = remainder.range(of: marker) {
            let after = remainder[range.upperBound...]
            guard let end = after.firstIndex(of: "\"") else { break }
            keys.append(String(after[..<end]))
            remainder = after[end...]
        }
        return keys
    }
}

enum StringListParseOutcome: Equatable {
    case success([String])
    case failure(String)
}
