// AppLog —— 统一日志出口（占位，见 docs/logging.md）。
// 只允许 Foundation：任何模块都不得绕过本出口直接 print / NSLog。
import Foundation

/// 日志分级。
public enum LogLevel: String, CaseIterable, Sendable, Comparable {
    case debug, info, warning, error

    private var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }
}

/// 日志分类（按子系统切分，便于过滤）。
public enum LogCategory: String, CaseIterable, Sendable {
    case app, pipeline, capture, vision, dewarp, export, storage
}

/// 日志落地目标；默认写 stderr，文件目标由 platforms 层注入（见 docs/logging.md 的轮转上限）。
public protocol LogSink: Sendable {
    func write(_ line: String)
}

/// stderr 落地目标。
public struct StandardErrorLogSink: LogSink {
    public init() {}

    public func write(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}

/// 进程内统一日志出口。`os.Logger` 扇出由 platforms 层在装配时追加 sink。
public enum AppLog {
    /// 最低输出级别；默认 info（debug 在 Release 静默）。
    public static let minimumLevel: LogLevel = {
        #if DEBUG
            return .debug
        #else
            return .info
        #endif
    }()

    private static let lock = NSLock()
    private static var sinks: [LogSink] = [StandardErrorLogSink()]

    public static func addSink(_ sink: LogSink) {
        lock.lock()
        defer { lock.unlock() }
        sinks.append(sink)
    }

    public static func debug(_ message: String, category: LogCategory) { log(.debug, message, category) }
    public static func info(_ message: String, category: LogCategory) { log(.info, message, category) }
    public static func warning(_ message: String, category: LogCategory) { log(.warning, message, category) }
    public static func error(_ message: String, category: LogCategory) { log(.error, message, category) }

    static func log(_ level: LogLevel, _ message: String, _ category: LogCategory) {
        guard level >= minimumLevel else { return }
        let line = "[\(category.rawValue)][\(level.rawValue)] \(message)"
        lock.lock()
        let current = sinks
        lock.unlock()
        for sink in current { sink.write(line) }
    }
}
