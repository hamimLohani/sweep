import ArgumentParser
import Foundation
import SweepCore

struct ScanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Scan an application and all its detected leftover files without deleting anything."
    )

    @Argument(help: "Application name, path to .app, or bundle identifier.")
    var target: String

    @Flag(name: .long, help: "Output results in JSON format.")
    var json: Bool = false

    func run() throws {
        let resolver = AppResolver()
        let app = try resolver.resolve(target: target)

        let scanner = LeftoverScanner()
        let result = try scanner.scan(appInfo: app)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(result)
            if let output = String(data: data, encoding: .utf8) {
                print(output)
            }
            return
        }

        // Human-readable CLI formatting
        Formatters.printAppSummary(result.appInfo)

        if result.leftovers.isEmpty {
            print(Terminal.colorize("No leftover files or caches detected for this application.", .yellow))
            print("\n" + Terminal.bold("Total Space: ") + Terminal.formatBytes(result.totalSizeBytes))
            return
        }

        print(Terminal.bold("Detected Leftover Files (\(result.leftovers.count) items):"))
        print(Terminal.dim(String(repeating: "─", count: 70)))

        let grouped = result.groupedByCategory
        for category in grouped.keys.sorted() {
            let items = grouped[category] ?? []
            let catTotal = items.reduce(0) { $0 + $1.sizeBytes }
            print(Terminal.bold("\n📂 \(category)") + " " + Terminal.dim("(\(items.count) items, \(Terminal.formatBytes(catTotal)))"))

            for item in items {
                let badge = Formatters.confidenceBadge(item.confidence)
                let pathStr = Formatters.formatPath(item.url)
                let sizeStr = Terminal.formatBytes(item.sizeBytes)
                let privStr = item.requiresPrivilege ? Terminal.colorize(" [sudo required]", .boldRed) : ""

                print("  \(badge) \(pathStr) " + Terminal.colorize("(\(sizeStr))", .cyan) + privStr)
                print("         " + Terminal.dim("↳ \(item.matchReason)"))
            }
        }

        print(Terminal.dim("\n" + String(repeating: "─", count: 70)))
        print(Terminal.bold("Application Size:  ") + Terminal.formatBytes(result.appInfo.bundleSizeBytes))
        let leftoversSize = result.leftovers.reduce(0) { $0 + $1.sizeBytes }
        print(Terminal.bold("Leftovers Size:    ") + Terminal.colorize(Terminal.formatBytes(leftoversSize), .yellow))
        print(Terminal.bold("Total Disk Usage:  ") + Terminal.colorize(Terminal.formatBytes(result.totalSizeBytes), .boldCyan))

        if result.hasPrivilegedItems {
            print(Terminal.colorize("\n⚠️  Some items reside in system directories (/Library) and will require administrator privileges to remove.", .boldYellow))
        }

        print(Terminal.dim("\n💡 This was a scan only. No files were modified or deleted."))
        if app.isSystemApp || SafetyGuard.isProtectedSystemApp(bundleIdentifier: app.bundleIdentifier, bundleURL: app.bundleURL) {
            print(Terminal.colorize("   '\(app.displayName)' is a core macOS system application and cannot be uninstalled.", .yellow))
            print(Terminal.dim("   To clean its temporary caches safely, run:") + " " + Terminal.bold("sweep remove cache \"\(app.displayName)\""))
        } else {
            print(Terminal.dim("   To remove this application and its leftovers, run:") + " " + Terminal.bold("sweep remove \"\(target)\""))
        }
    }
}
