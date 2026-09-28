import ArgumentParser
import Foundation
import SweepCore

struct RemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Scan and safely remove an application and its leftovers, or clean caches via 'remove cache'.",
        discussion: """
        Uninstalls an application bundle along with its leftover preferences,
        caches, sandboxed containers, and background helper services.

        CACHE CLEANING:
          sweep remove cache <app>      Clean cache locations for an application (e.g. Safari)
          sweep remove cache all        Clean cache locations for all installed applications
          sweep remove <app> --cache    Flag syntax to clean application cache
        """
    )

    @Argument(help: "Application name, path to .app, bundle identifier, or 'cache' to clean application caches.")
    var target: String

    @Argument(help: "Application name or 'all' when cleaning cache (e.g. sweep remove cache Safari).")
    var appName: String?

    @Flag(name: .long, help: "Perform a trial run without moving or deleting any files.")
    var dryRun: Bool = false

    @Flag(name: [.short, .long], help: "Skip interactive confirmation and remove all discovered items.")
    var yes: Bool = false

    @Flag(name: .long, help: "Permanently delete files instead of moving them to the Trash (Caution).")
    var permanent: Bool = false

    @Flag(name: .long, help: "Output results in JSON format.")
    var json: Bool = false

    @Flag(name: .long, help: "Include low-confidence (vendor/fuzzy) matches in the removal candidates.")
    var includeLowConfidence: Bool = false

    @Flag(name: .long, help: "Clean cache only, preserving the application and its user settings.")
    var cache: Bool = false

    @Flag(name: .long, help: "Clean caches for all installed applications.")
    var all: Bool = false

    func run() throws {
        let isCacheMode = target.lowercased() == "cache" || cache
        if isCacheMode {
            if target.lowercased() == "cache" {
                if let subApp = appName, subApp.lowercased() != "all" {
                    try handleSingleAppCacheClean(appName: subApp)
                } else {
                    try handleAllAppCachesClean()
                }
            } else {
                try handleSingleAppCacheClean(appName: target)
            }
            return
        }

        // 1. Resolve target for regular uninstallation
        let resolver = AppResolver()
        let app = try resolver.resolve(target: target)

        // Safety check: protect sealed core Apple system applications
        if app.isSystemApp || SafetyGuard.isProtectedSystemApp(bundleIdentifier: app.bundleIdentifier, bundleURL: app.bundleURL) {
            throw SweepError.protectedSystemComponent("Target '\(app.bundleName)' (\(app.bundleIdentifier)) is a sealed macOS system-protected application. To clean its caches, use: sweep remove cache \"\(app.bundleName)\"")
        }

        // 2. Check if application is currently running
        let processManager = ProcessManager.shared
        if processManager.isAppRunning(bundleIdentifier: app.bundleIdentifier) {
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
                print(Terminal.dim("Stopping '\(app.displayName)'..."))
                let quitSuccess = processManager.quitApp(bundleIdentifier: app.bundleIdentifier)
                if !quitSuccess {
                    throw SweepError.runningAppRefusedQuit(app.displayName)
                }
            }
        }

        // 3. Scan for leftovers
        let scanner = LeftoverScanner()
        let scanResult = try scanner.scan(appInfo: app)

        // 4. Interactive selection or batch selection
        guard let selectedLeftovers = InteractiveChecklist.selectItems(
            candidates: scanResult.leftovers,
            includeLowConfidence: includeLowConfidence,
            autoConfirm: yes
        ) else {
            print(Terminal.colorize("Removal cancelled by user.", .yellow))
            return
        }

        // 5. Construct RemovalPlan
        let plan = RemovalPlan(
            appInfo: app,
            selectedItems: selectedLeftovers,
            isPermanent: permanent,
            dryRun: dryRun
        )

        if dryRun && !json {
            print(Terminal.colorize("\n[DRY RUN MODE] Simulating removal of \(plan.totalItemsCount) items (\(Terminal.formatBytes(plan.totalSizeBytes))):", .boldCyan))
        }

        // 6. Final confirmation if not already auto-confirmed with -y
        if !yes && !dryRun {
            let actionName = permanent ? "PERMANENTLY DELETE" : "move to Trash"
            let warningColor = permanent ? TerminalColor.boldRed : TerminalColor.boldYellow
            print("\n" + Terminal.colorize("Are you sure you want to \(actionName) \(plan.totalItemsCount) items (\(Terminal.formatBytes(plan.totalSizeBytes)))?", warningColor) + " [y/N]: ", terminator: "")
            fflush(stdout)
            let confirm = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "n"
            guard confirm == "y" || confirm == "yes" else {
                print(Terminal.colorize("Operation aborted.", .yellow))
                return
            }
        }

        // 7. Check for administrator privileges if any targets are protected or non-writable
        if !dryRun {
            let privilegeHandler = PrivilegeHandler.shared
            let requiresPrivilege = !privilegeHandler.canWrite(to: app.bundleURL) ||
                selectedLeftovers.contains(where: { $0.requiresPrivilege || !privilegeHandler.canWrite(to: $0.url) })
            if requiresPrivilege && !privilegeHandler.isRoot {
                if !privilegeHandler.hasCachedSudo() {
                    print(Terminal.colorize("\n🔒 Administrator privileges (sudo) required for this uninstallation.", .boldYellow))
                    print(Terminal.dim("Please enter your password if prompted by macOS.\n"))
                }
                try privilegeHandler.authenticateIfNeeded()
            }
        }

        // 8. Execute TrashRemover (prints each file path before deleting)
        let remover = TrashRemover()
        let result = try remover.execute(plan: plan) { url, category in
            let actionPrefix = dryRun ? "[WOULD REMOVE]" : (permanent ? "[DELETING]" : "[TRASHING]")
            print(Terminal.colorize("\(actionPrefix) ", .cyan) + Terminal.bold(url.path) + Terminal.dim(" (\(category))"))
        }

        // 8. Output results
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(result.record)
            if let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            return
        }

        print(Terminal.dim("\n" + String(repeating: "─", count: 70)))
        if dryRun {
            print(Terminal.colorize("✓ Dry run complete. No files were modified or moved.", .boldGreen))
        } else if result.isCompleteSuccess {
            let verb = permanent ? "Permanently deleted" : "Moved to Trash"
            print(Terminal.colorize("✓ \(verb) \(result.successfulItems.count) items (\(Terminal.formatBytes(plan.totalSizeBytes))).", .boldGreen))
            print(Terminal.dim("  Audit log written to ~/.config/sweep/history.json"))
        } else {
            print(Terminal.colorize("⚠️  Completed with some errors:", .boldYellow))
            print("  Successfully processed: \(result.successfulItems.count) items")
            print("  Failed to process:       \(result.failedItems.count) items")
            for failed in result.failedItems {
                print(Terminal.colorize("  ✖ \(failed.url.path): \(failed.errorMessage ?? "Permission error")", .red))
            }
            throw SweepError.permissionDenied("Some items could not be removed. Try running with sudo if system files are involved.")
        }
    }

    private func handleAllAppCachesClean() throws {
        if !json {
            print(Terminal.bold("Scanning all installed applications for cache files..."))
        }

        let scanner = CacheScanner()
        let allCaches = scanner.scanAllAppCaches()

        if allCaches.isEmpty {
            if !json {
                print(Terminal.colorize("No application caches detected.", .yellow))
            }
            return
        }

        let totalBytes = allCaches.reduce(0) { $0 + $1.totalSizeBytes }
        let totalItems = allCaches.reduce(0) { $0 + $1.cacheItems.count }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(allCaches)
            if let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            return
        }

        print("\n" + Terminal.colorize("Discovered caches for \(allCaches.count) applications (\(Terminal.formatBytes(totalBytes)) across \(totalItems) locations):", .boldCyan))
        print(Terminal.dim(String(repeating: "─", count: 70)))

        for appCache in allCaches {
            let countStr = "\(appCache.cacheItems.count) items"
            print("  • " + Terminal.bold(appCache.appInfo.displayName) + " " + Terminal.colorize("(\(Terminal.formatBytes(appCache.totalSizeBytes)))", .cyan) + " " + Terminal.dim("[\(countStr)]"))
        }

        print(Terminal.dim(String(repeating: "─", count: 70)))

        if !yes && !dryRun {
            print("\n" + Terminal.colorize("Are you sure you want to clean caches for all \(allCaches.count) applications (\(Terminal.formatBytes(totalBytes)))?", .boldYellow) + " [y/N]: ", terminator: "")
            fflush(stdout)
            let confirm = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "n"
            guard confirm == "y" || confirm == "yes" else {
                print(Terminal.colorize("Operation aborted.", .yellow))
                return
            }
        }

        // Mandatory administrator privilege authentication as requested
        if !dryRun {
            if !PrivilegeHandler.shared.hasCachedSudo() {
                print(Terminal.colorize("\n🔒 Administrator privileges (sudo) required to clean application caches.", .boldYellow))
                print(Terminal.dim("Please enter your administrator password if prompted by macOS.\n"))
            }
            try PrivilegeHandler.shared.authenticateIfNeeded()
        }

        let cleaner = CacheCleaner()
        var totalFreed: Int64 = 0
        var totalSuccessCount = 0

        for appCache in allCaches {
            let res = try cleaner.clean(items: appCache.cacheItems, appInfo: appCache.appInfo, dryRun: dryRun) { url, category, size in
                let prefix = dryRun ? "[WOULD CLEAN]" : "[CLEANING CACHE]"
                print(Terminal.colorize("\(prefix) ", .cyan) + Terminal.bold(url.path) + " " + Terminal.colorize("(\(Terminal.formatBytes(size)))", .yellow))
            }
            totalFreed += res.totalFreedBytes
            totalSuccessCount += res.successfulItems.count
        }

        print(Terminal.dim("\n" + String(repeating: "─", count: 70)))
        if dryRun {
            print(Terminal.colorize("✓ Dry run complete. Would clean \(totalItems) cache locations (\(Terminal.formatBytes(totalBytes))).", .boldGreen))
        } else {
            print(Terminal.colorize("✓ Successfully cleaned \(totalSuccessCount) cache locations (\(Terminal.formatBytes(totalFreed)) freed).", .boldGreen))
            print(Terminal.dim("  Audit log written to ~/.config/sweep/history.json"))
        }
    }

    private func handleSingleAppCacheClean(appName: String) throws {
        let resolver = AppResolver()
        let app = try resolver.resolve(target: appName)

        if !json {
            Formatters.printAppSummary(app)
        }

        let scanner = CacheScanner()
        let cacheInfo = scanner.scanCache(for: app)

        if cacheInfo.cacheItems.isEmpty {
            if !json {
                print(Terminal.colorize("No cache files detected for '\(app.displayName)'.", .yellow))
            }
            return
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(cacheInfo)
            if let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            return
        }

        print(Terminal.bold("Discovered Cache Locations (\(cacheInfo.cacheItems.count) items):"))
        print(Terminal.dim(String(repeating: "─", count: 70)))

        for item in cacheInfo.cacheItems {
            let pathStr = Formatters.formatPath(item.url)
            let sizeStr = Terminal.formatBytes(item.sizeBytes)
            print("  • " + pathStr + " " + Terminal.colorize("(\(sizeStr))", .cyan))
            print("    " + Terminal.dim("↳ \(item.category): \(item.matchReason)"))
        }

        print(Terminal.dim(String(repeating: "─", count: 70)))
        print(Terminal.bold("Total Cache Disk Usage: ") + Terminal.colorize(Terminal.formatBytes(cacheInfo.totalSizeBytes), .boldCyan))

        if !yes && !dryRun {
            print("\n" + Terminal.colorize("Are you sure you want to clean caches for '\(app.displayName)' (\(Terminal.formatBytes(cacheInfo.totalSizeBytes)))?", .boldYellow) + " [y/N]: ", terminator: "")
            fflush(stdout)
            let confirm = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "n"
            guard confirm == "y" || confirm == "yes" else {
                print(Terminal.colorize("Operation aborted.", .yellow))
                return
            }
        }

        // Mandatory administrator privilege authentication as requested
        if !dryRun {
            if !PrivilegeHandler.shared.hasCachedSudo() {
                print(Terminal.colorize("\n🔒 Administrator privileges (sudo) required to clean application caches.", .boldYellow))
                print(Terminal.dim("Please enter your administrator password if prompted by macOS.\n"))
            }
            try PrivilegeHandler.shared.authenticateIfNeeded()
        }

        let cleaner = CacheCleaner()
        let result = try cleaner.clean(items: cacheInfo.cacheItems, appInfo: app, dryRun: dryRun) { url, category, size in
            let prefix = dryRun ? "[WOULD CLEAN]" : "[CLEANING CACHE]"
            print(Terminal.colorize("\(prefix) ", .cyan) + Terminal.bold(url.path) + " " + Terminal.colorize("(\(Terminal.formatBytes(size)))", .yellow))
        }

        print(Terminal.dim("\n" + String(repeating: "─", count: 70)))
        if dryRun {
            print(Terminal.colorize("✓ Dry run complete. Would clean \(cacheInfo.cacheItems.count) cache locations (\(Terminal.formatBytes(cacheInfo.totalSizeBytes))).", .boldGreen))
        } else {
            print(Terminal.colorize("✓ Successfully cleaned \(result.successfulItems.count) cache locations (\(Terminal.formatBytes(result.totalFreedBytes)) freed).", .boldGreen))
            print(Terminal.dim("  Audit log written to ~/.config/sweep/history.json"))
        }
    }
}
