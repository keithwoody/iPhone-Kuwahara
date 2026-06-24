public final class LBLogger: @unchecked Sendable {
    public static func with(_ identifier: String) -> LBLogger { LBLogger() }
    public enum Level { case trace, info, warn, error }
    public func isEnabledFor(level: Level) -> Bool { false }
    public func trace(_ items: Any..., file: String = #file, function: String = #function, line: Int = #line) {}
    public func info(_ items: Any..., file: String = #file, function: String = #function, line: Int = #line) {}
    public func warn(_ items: Any..., file: String = #file, function: String = #function, line: Int = #line) {}
    public func error(_ items: Any..., file: String = #file, function: String = #function, line: Int = #line) {}
}
