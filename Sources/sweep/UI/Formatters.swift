import Foundation
import SweepCore

public struct Formatters {
    public static func confidenceBadge(_ confidence: Confidence) -> String {
        switch confidence {
        case .high:
            return Terminal.colorize("[HIGH]", .boldGreen)
        case .medium:
            return Terminal.colorize("[MED] ", .boldYellow)
        case .low:
            return Terminal.colorize("[LOW] ", .dim)
        }
    }

    public static func formatPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    public static func printAppSummary(_ app: AppInfo) {
        print(Terminal.bold("Application: ") + Terminal.colorize(app.displayName, .boldCyan))
        print(Terminal.bold("Bundle ID:   ") + Terminal.colorize(app.bundleIdentifier, .cyan))
        if let version = app.version {
            print(Terminal.bold("Version:     ") + version)
        }
        print(Terminal.bold("App Path:    ") + formatPath(app.bundleURL))
        print(Terminal.bold("App Size:    ") + Terminal.formatBytes(app.bundleSizeBytes))
        if !app.receiptPackages.isEmpty {
            print(Terminal.bold("Installer:   ") + "Package receipt (\(app.receiptPackages.joined(separator: ", ")))")
        }
        print(Terminal.dim(String(repeating: "─", count: 65)))
    }
}
