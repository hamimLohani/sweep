import ArgumentParser
import Foundation
import SweepCore

struct BrewCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "brew",
        abstract: "List, scan, and uninstall Homebrew packages (formulae & casks) with leftover cleanup.",
        discussion: """
        Integrates with Homebrew (`brew`) to inspect installed formulae and casks,
        compute disk usage including Cellar/Caskroom, app bundles, download caches,
        config/data directories, and cask zap targets, and cleanly uninstall packages
        without leaving orphaned files behind.

        EXAMPLES:
          sweep brew list
          sweep brew list --casks
          sweep brew list --leaves
          sweep brew scan neovide-app
          sweep brew remove neovide-app --dry-run
          sweep brew remove bat --autoremove
        """,
        subcommands: [
            BrewListCommand.self,
            BrewScanCommand.self,
            BrewRemoveCommand.self
        ]
    )
}

struct BrewListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List installed Homebrew formulae and casks."
    )

    @Flag(name: [.long], help: "Show Homebrew formulae only.")
    var formulae: Bool = false

    @Flag(name: [.long], help: "Show Homebrew casks only.")
    var casks: Bool = false

    @Flag(name: .long, help: "Show only leaf packages not depended on by other installed packages.")
    var leaves: Bool = false

    @Flag(name: .long, help: "Show only outdated packages.")
    var outdated: Bool = false

    @Option(name: [.short, .long], help: "Filter packages by name, alias, or description.")
    var filter: String?

    @Flag(name: .long, help: "Output results in JSON format.")
    var json: Bool = false

    func run() throws {
        if formulae && casks {
            throw SweepError.general("Cannot specify both --formulae and --casks.")
        }
        let kind: HomebrewPackageKind? = formulae ? .formula : (casks ? .cask : nil)

        let resolver = HomebrewResolver()
        let packages = try resolver.listInstalledPackages(
            kind: kind,
            leavesOnly: leaves,
            outdatedOnly: outdated,
            filter: filter
        )

        if json {
            let data = try Formatters.jsonEncoder().encode(packages)
            if let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            return
        }

        guard !packages.isEmpty else {
            print(Terminal.colorize("No matching Homebrew packages found.", .yellow))
            return
        }

        print(Terminal.bold("Installed Homebrew Packages (\(packages.count) found):"))
        print(Terminal.dim(String(repeating: "─", count: 96)))

        let maxNameLen = min(max(packages.map { $0.fullName.count }.max() ?? 24, 20), 34)
        let maxVerLen = min(max(packages.map { $0.version.count }.max() ?? 12, 10), 22)
        let maxTapLen = min(max(packages.map { $0.tap.count }.max() ?? 16, 14), 22)

        let header = "Package".padding(toLength: maxNameLen, withPad: " ", startingAt: 0) + "  " +
                     "Type".padding(toLength: 9, withPad: " ", startingAt: 0) + "  " +
                     "Version".padding(toLength: maxVerLen, withPad: " ", startingAt: 0) + "  " +
                     "Tap".padding(toLength: maxTapLen, withPad: " ", startingAt: 0)
        print(Terminal.bold(header))
        print(Terminal.dim(String(repeating: "─", count: 96)))

        for pkg in packages {
            let nameCol = truncate(pkg.fullName, to: maxNameLen).padding(toLength: maxNameLen, withPad: " ", startingAt: 0)
            let typeCol = pkg.kind.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)
            let verCol = truncate(pkg.version, to: maxVerLen).padding(toLength: maxVerLen, withPad: " ", startingAt: 0)
            let tapCol = truncate(pkg.tap, to: maxTapLen).padding(toLength: maxTapLen, withPad: " ", startingAt: 0)

            var tags: [String] = []
            if pkg.isOutdated { tags.append("outdated") }
            if pkg.isPinned { tags.append("pinned") }
            if pkg.serviceRunning { tags.append("running") }
            let tagStr = tags.isEmpty ? "" : " " + Terminal.colorize("[\(tags.joined(separator: ", "))]", .yellow)

            print("\(nameCol)  \(typeCol)  \(verCol)  \(tapCol)\(tagStr)")
        }

        print(Terminal.dim(String(repeating: "─", count: 96)))
        let formulaCount = packages.filter { $0.kind == .formula }.count
        let caskCount = packages.filter { $0.kind == .cask }.count
        print(Terminal.bold("Total: ") + "\(packages.count) packages (\(formulaCount) formulae, \(caskCount) casks)")
    }

    private func truncate(_ value: String, to maxLen: Int) -> String {
        guard value.count > maxLen, maxLen > 1 else { return value }
        return String(value.prefix(maxLen - 1)) + "…"
    }
}

struct BrewScanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Scan an installed Homebrew formula or cask for artifacts, caches, zap paths, and leftovers."
    )

    @Argument(help: "Homebrew formula name, cask token, or full tap name.")
    var target: String

    @Flag(name: .long, help: "Only search Homebrew formulae.")
    var formula: Bool = false

    @Flag(name: .long, help: "Only search Homebrew casks.")
    var cask: Bool = false

    @Flag(name: .long, help: "Output results in JSON format.")
    var json: Bool = false

    func run() throws {
        let preferredKind = try BrewCommandHelpers.resolveKindFlag(formula: formula, cask: cask)
        let resolver = HomebrewResolver()
        let pkg = try resolver.resolve(target: target, preferredKind: preferredKind)
        try BrewCommandHelpers.runScan(for: pkg, json: json)
    }
}

struct BrewRemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Uninstall a Homebrew formula or cask and clean its caches, zap targets, and leftovers."
    )

    @Argument(help: "Homebrew formula name, cask token, or full tap name.")
    var target: String

    @Flag(name: .long, help: "Only search Homebrew formulae.")
    var formula: Bool = false

    @Flag(name: .long, help: "Only search Homebrew casks.")
    var cask: Bool = false

    @Flag(name: .long, help: "Simulate uninstallation and cleanup without modifying any files.")
    var dryRun: Bool = false

    @Flag(name: [.short, .long], help: "Skip interactive confirmation prompts.")
    var yes: Bool = false

    @Flag(name: .long, help: "Permanently delete leftover/cache files instead of moving to Trash.")
    var permanent: Bool = false

    @Flag(name: .long, help: "Include low-confidence runtime leftovers in cleanup candidates.")
    var includeLowConfidence: Bool = false

    @Flag(name: .long, help: "Uninstall formula even if other installed packages depend on it.")
    var ignoreDependencies: Bool = false

    @Flag(name: .long, help: "Pass --force to 'brew uninstall'.")
    var force: Bool = false

    @Flag(name: .long, help: "Run 'brew autoremove' afterwards to prune orphaned dependencies.")
    var autoremove: Bool = false

    @Flag(name: .long, help: "Run 'brew uninstall' only, without removing leftovers, zap paths, or caches.")
    var noLeftovers: Bool = false

    @Flag(name: .long, help: "Output results in JSON format.")
    var json: Bool = false

    func run() throws {
        let preferredKind = try BrewCommandHelpers.resolveKindFlag(formula: formula, cask: cask)
        let resolver = HomebrewResolver()
        let pkg = try resolver.resolve(target: target, preferredKind: preferredKind)
        try BrewCommandHelpers.runRemove(
            for: pkg,
            dryRun: dryRun,
            yes: yes,
            permanent: permanent,
            includeLowConfidence: includeLowConfidence,
            ignoreDependencies: ignoreDependencies,
            force: force,
            autoremove: autoremove,
            noLeftovers: noLeftovers,
            json: json
        )
    }
}

/// Shared execution helpers used by both `sweep brew` and unified `sweep pkg`.
enum BrewCommandHelpers {
    static func resolveKindFlag(formula: Bool, cask: Bool) throws -> HomebrewPackageKind? {
        if formula && cask {
            throw SweepError.general("Cannot specify both --formula and --cask.")
        }
        if formula { return .formula }
        if cask { return .cask }
        return nil
    }

    static func runScan(for pkg: HomebrewPackageInfo, json: Bool) throws {
        let scanner = HomebrewScanner()
        let result = try scanner.scan(packageInfo: pkg)

        if json {
            let data = try Formatters.jsonEncoder().encode(result)
            if let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            return
        }

        Formatters.printHomebrewSummary(result.packageInfo)

        if let cellarURL = pkg.cellarOrCaskroomURL {
            let label = pkg.kind == .cask ? "Caskroom" : "Cellar"
            print(Terminal.bold("📦 Homebrew \(label): ") + Formatters.formatPath(cellarURL) + " " + Terminal.colorize("(\(Terminal.formatBytes(result.cellarSizeBytes)))", .cyan))
        }

        if !result.artifactItems.isEmpty {
            print(Terminal.bold("\n📦 Installed Cask Artifacts (\(result.artifactItems.count) items):"))
            for item in result.artifactItems {
                let pathStr = Formatters.formatPath(item.url)
                let sizeStr = Terminal.formatBytes(item.sizeBytes)
                let privStr = item.requiresPrivilege ? Terminal.colorize(" [sudo required]", .boldRed) : ""
                print("  • \(pathStr) " + Terminal.colorize("(\(sizeStr))", .cyan) + privStr)
            }
        }

        if result.cleanupItems.isEmpty {
            print("\n" + Terminal.colorize("No additional leftover, zap, or download cache files detected.", .yellow))
        } else {
            print("\n" + Terminal.bold("Detected Leftovers, Zap Data & Caches (\(result.cleanupItems.count) items):"))
            print(Terminal.dim(String(repeating: "─", count: 70)))

            let grouped = result.groupedCleanupByCategory
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
        }

        if !result.orphanedDependencies.isEmpty {
            print("\n" + Terminal.colorize("🧹 Orphaned Dependencies (removable via --autoremove):", .boldYellow) + " " + result.orphanedDependencies.joined(separator: ", "))
        }

        let artifactsSum = result.artifactItems.reduce(0) { $0 + $1.sizeBytes }
        print(Terminal.dim("\n" + String(repeating: "─", count: 70)))
        print(Terminal.bold("Cellar/Caskroom Size: ") + Terminal.formatBytes(result.cellarSizeBytes))
        if artifactsSum > 0 {
            print(Terminal.bold("Artifacts Size:       ") + Terminal.formatBytes(artifactsSum))
        }
        print(Terminal.bold("Leftovers & Caches:   ") + Terminal.colorize(Terminal.formatBytes(result.cleanupSizeBytes), .yellow))
        print(Terminal.bold("Total Disk Usage:     ") + Terminal.colorize(Terminal.formatBytes(result.totalSizeBytes), .boldCyan))

        if !pkg.requiredBy.isEmpty {
            print(Terminal.colorize("\n⚠️  '\(pkg.name)' is required by: \(pkg.requiredBy.joined(separator: ", ")).", .boldYellow))
        }
        if result.hasPrivilegedItems {
            print(Terminal.colorize("\n⚠️  Some items reside in system directories and require administrator privileges to clean.", .boldYellow))
        }

        print(Terminal.dim("\n💡 This was a scan only. No files were modified or uninstalled."))
        print(Terminal.dim("   To uninstall and clean leftovers, run: ") + Terminal.bold("sweep brew remove \"\(pkg.fullName)\""))
    }

    static func runRemove(
        for pkg: HomebrewPackageInfo,
        dryRun: Bool,
        yes: Bool,
        permanent: Bool,
        includeLowConfidence: Bool,
        ignoreDependencies: Bool,
        force: Bool,
        autoremove: Bool,
        noLeftovers: Bool,
        json: Bool
    ) throws {
        if pkg.kind == .formula && !pkg.requiredBy.isEmpty && !ignoreDependencies && !force {
            throw SweepError.general(
                "Formula '\(pkg.name)' is required by: \(pkg.requiredBy.joined(separator: ", ")). Pass --ignore-dependencies to uninstall anyway."
            )
        }
        if pkg.isPinned && !force {
            throw SweepError.general("Package '\(pkg.name)' is pinned in Homebrew. Unpin it first or pass --force.")
        }

        let scanner = HomebrewScanner()
        let scanResult = try scanner.scan(packageInfo: pkg)

        if !json {
            Formatters.printHomebrewSummary(pkg)
        }

        // Quit any running .app bundles owned by this cask
        let processManager = ProcessManager.shared
        for app in scanResult.discoveredAppBundles {
            if !app.bundleIdentifier.isEmpty, processManager.isAppRunning(bundleIdentifier: app.bundleIdentifier) {
                if !yes && !dryRun {
                    print(Terminal.colorize("⚠️  '\(app.displayName)' is currently running.", .boldYellow))
                    print(Terminal.bold("Quit the application before proceeding? [Y/n]: "), terminator: "")
                    fflush(stdout)
                    let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "y"
                    if answer == "n" || answer == "no" {
                        throw SweepError.runningAppRefusedQuit(app.displayName)
                    }
                }
                if !dryRun {
                    if !json { print(Terminal.dim("Stopping '\(app.displayName)'...")) }
                    guard processManager.quitApp(bundleIdentifier: app.bundleIdentifier) else {
                        throw SweepError.runningAppRefusedQuit(app.displayName)
                    }
                }
            }
        }

        let selectedCleanup: [LeftoverItem]
        if noLeftovers || scanResult.cleanupItems.isEmpty {
            selectedCleanup = []
        } else {
            guard let picked = InteractiveChecklist.selectItems(
                candidates: scanResult.cleanupItems,
                includeLowConfidence: includeLowConfidence,
                autoConfirm: yes || json
            ) else {
                print(Terminal.colorize("Removal cancelled by user.", .yellow))
                return
            }
            selectedCleanup = picked
        }

        let artifactSize = scanResult.artifactItems.reduce(0) { $0 + $1.sizeBytes }
        let plan = HomebrewRemovalPlan(
            packageInfo: pkg,
            selectedCleanupItems: selectedCleanup,
            isPermanent: permanent,
            dryRun: dryRun,
            ignoreDependencies: ignoreDependencies,
            force: force,
            autoremove: autoremove,
            cellarSizeBytes: scanResult.cellarSizeBytes,
            artifactSizeBytes: artifactSize
        )

        if dryRun && !json {
            print(Terminal.colorize("\n[DRY RUN MODE] Simulating uninstall of '\(pkg.fullName)' + \(selectedCleanup.count) cleanup items (\(Terminal.formatBytes(plan.totalSizeBytes))):", .boldCyan))
        }

        if !yes && !dryRun {
            let cleanupDesc = selectedCleanup.isEmpty ? "" : " and remove \(selectedCleanup.count) leftover/cache item(s)"
            let autoremoveDesc = autoremove ? " + prune orphaned dependencies" : ""
            let promptText = "Uninstall Homebrew \(pkg.kind.rawValue) '\(pkg.fullName)'\(cleanupDesc)\(autoremoveDesc) (\(Terminal.formatBytes(plan.totalSizeBytes)))?"
            print("\n" + Terminal.colorize(promptText, .boldYellow) + " [y/N]: ", terminator: "")
            fflush(stdout)
            let confirm = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "n"
            guard confirm == "y" || confirm == "yes" else {
                print(Terminal.colorize("Operation aborted.", .yellow))
                return
            }
        }

        let needsSudo = !dryRun && (plan.hasPrivilegedItems || selectedCleanup.contains { !PrivilegeHandler.shared.canWrite(to: $0.url) })
        if needsSudo {
            let privilegeHandler = PrivilegeHandler.shared
            if !privilegeHandler.isRoot {
                if !privilegeHandler.hasCachedSudo() && !json {
                    print(Terminal.colorize("\n🔒 Administrator privileges (sudo) required to clean system-level leftover files.", .boldYellow))
                }
                try privilegeHandler.authenticateIfNeeded()
            }
        }

        let remover = HomebrewRemover()
        let result = try remover.execute(
            plan: plan,
            onStep: { step in
                if !json {
                    print(Terminal.colorize(step, .cyan))
                }
            },
            onItemWillDelete: { url, category in
                guard !json else { return }
                let prefix = dryRun ? "[WOULD REMOVE]" : (permanent ? "[DELETING]" : "[TRASHING]")
                print(Terminal.colorize("\(prefix) ", .cyan) + Terminal.bold(url.path) + Terminal.dim(" (\(category))"))
            }
        )

        if json {
            let data = try Formatters.jsonEncoder().encode(result.record)
            if let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            return
        }

        print(Terminal.dim("\n" + String(repeating: "─", count: 70)))
        if dryRun {
            if let preview = result.autoremoveOutput, !preview.isEmpty {
                print(Terminal.dim(preview))
            }
            print(Terminal.colorize("✓ Dry run complete. No packages or files were modified.", .boldGreen))
            return
        }

        if result.isCompleteSuccess {
            print(Terminal.colorize("✓ Uninstalled Homebrew \(pkg.kind.rawValue) '\(pkg.fullName)'.", .boldGreen))
            if !result.successfulCleanupItems.isEmpty {
                let verb = permanent ? "Permanently deleted" : "Moved to Trash"
                print(Terminal.colorize("✓ \(verb) \(result.successfulCleanupItems.count) leftover/cache item(s).", .boldGreen))
            }
            if result.autoremoveExecuted, let out = result.autoremoveOutput, !out.isEmpty {
                print(Terminal.dim("  Autoremove: \(out)"))
            }
            if !scanResult.orphanedDependencies.isEmpty && !autoremove {
                print(Terminal.dim("  Tip: Run 'brew autoremove' to remove orphaned dependencies: \(scanResult.orphanedDependencies.joined(separator: ", "))"))
            }
            print(Terminal.dim("  Audit log written to ~/.config/sweep/history.json"))
        } else {
            print(Terminal.colorize("⚠️  Completed with some cleanup errors:", .boldYellow))
            for failed in result.failedCleanupItems {
                print(Terminal.colorize("  ✖ \(failed.url.path): \(failed.errorMessage ?? "Permission error")", .red))
            }
            throw SweepError.permissionDenied("Some package leftover items could not be removed cleanly.")
        }
    }
}
