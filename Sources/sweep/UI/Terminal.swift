import Foundation

public enum TerminalColor: String {
    case reset = "\u{001B}[0m"
    case bold = "\u{001B}[1m"
    case dim = "\u{001B}[2m"
    case red = "\u{001B}[31m"
    case green = "\u{001B}[32m"
    case yellow = "\u{001B}[33m"
    case blue = "\u{001B}[34m"
    case magenta = "\u{001B}[35m"
    case cyan = "\u{001B}[36m"
    case white = "\u{001B}[37m"
    case boldRed = "\u{001B}[1;31m"
    case boldGreen = "\u{001B}[1;32m"
    case boldYellow = "\u{001B}[1;33m"
    case boldCyan = "\u{001B}[1;36m"
}

public struct Terminal {
    public static var isColorEnabled: Bool {
        if ProcessInfo.processInfo.environment["NO_COLOR"] != nil {
            return false
        }
        return isatty(STDOUT_FILENO) == 1
    }

    public static func colorize(_ text: String, _ color: TerminalColor) -> String {
        guard isColorEnabled else { return text }
        return "\(color.rawValue)\(text)\(TerminalColor.reset.rawValue)"
    }

    public static func bold(_ text: String) -> String {
        guard isColorEnabled else { return text }
        return "\(TerminalColor.bold.rawValue)\(text)\(TerminalColor.reset.rawValue)"
    }

    public static func dim(_ text: String) -> String {
        guard isColorEnabled else { return text }
        return "\(TerminalColor.dim.rawValue)\(text)\(TerminalColor.reset.rawValue)"
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
