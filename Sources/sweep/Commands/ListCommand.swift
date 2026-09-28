import ArgumentParser
import Foundation
import SweepCore

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List installed applications from /Applications and ~/Applications."
    )

    @Flag(name: .long, help: "Output results in JSON format.")
    var json: Bool = false

    func run() throws {
        let resolver = AppResolver()
        let apps = resolver.listInstalledApps()

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(apps)
            if let output = String(data: data, encoding: .utf8) {
                print(output)
            }
            return
        }

        guard !apps.isEmpty else {
            print(Terminal.colorize("No applications found in /Applications or ~/Applications.", .yellow))
            return
        }

        print(Terminal.bold("Installed Applications (\(apps.count) found):"))
        print(Terminal.dim(String(repeating: "─", count: 85)))

        let maxNameLen = min(max(apps.map { $0.displayName.count }.max() ?? 25, 20), 35)
        let maxBundleLen = min(max(apps.map { $0.bundleIdentifier.count }.max() ?? 30, 25), 45)

        let header = "Application".padding(toLength: maxNameLen, withPad: " ", startingAt: 0) + "  " +
                     "Bundle Identifier".padding(toLength: maxBundleLen, withPad: " ", startingAt: 0) + "  " +
                     "Size".padding(toLength: 10, withPad: " ", startingAt: 0)
        print(Terminal.bold(header))
        print(Terminal.dim(String(repeating: "─", count: 85)))

        var totalSize: Int64 = 0
        for app in apps {
            totalSize += app.bundleSizeBytes
            let rawName = app.displayName.count > maxNameLen ? String(app.displayName.prefix(maxNameLen - 1)) + "…" : app.displayName
            let rawBundle = app.bundleIdentifier.count > maxBundleLen ? String(app.bundleIdentifier.prefix(maxBundleLen - 1)) + "…" : app.bundleIdentifier

            let nameCol = rawName.padding(toLength: maxNameLen, withPad: " ", startingAt: 0)
            let bundleCol = rawBundle.padding(toLength: maxBundleLen, withPad: " ", startingAt: 0)
            let sizeCol = Terminal.formatBytes(app.bundleSizeBytes).padding(toLength: 10, withPad: " ", startingAt: 0)

            print("\(nameCol)  \(bundleCol)  \(sizeCol)")
        }

        print(Terminal.dim(String(repeating: "─", count: 85)))
        print(Terminal.bold("Total: ") + "\(apps.count) applications, " + Terminal.colorize(Terminal.formatBytes(totalSize), .boldCyan))
    }
}
