// RepoLayout —— 契约测试的仓库定位与扫描工具（见 docs/contract-register.md）。
import Foundation

enum RepoLayout {
    /// 仓库根：环境变量优先，否则从本文件路径上溯 4 层（Tests/ContractTests/Support → 根）。
    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["DDSCANNER_REPO_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
    }

    static func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    static func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url(relativePath).path)
    }

    static func text(_ relativePath: String) -> String {
        (try? String(contentsOf: url(relativePath), encoding: .utf8)) ?? ""
    }

    /// 递归收集 `roots` 下扩展名匹配的文件，返回仓库相对路径（已排序）。
    static func files(under roots: [String], extensions: Set<String>) -> [String] {
        var results = [String]()
        let manager = FileManager.default
        for root in roots {
            let base = url(root)
            guard let enumerator = manager.enumerator(atPath: base.path) else { continue }
            for case let entry as String in enumerator {
                let ext = (entry as NSString).pathExtension
                guard extensions.contains(ext) else { continue }
                let relative = root + "/" + entry
                if relative.contains("/.build/") || relative.contains("/DerivedData/") { continue }
                results.append(relative)
            }
        }
        return results.sorted()
    }

    static func readInputs(under roots: [String], extensions: Set<String>) -> [StructuralBudgetInput] {
        files(under: roots, extensions: extensions).map { path in
            StructuralBudgetInput(path: path, contents: text(path))
        }
    }
}
