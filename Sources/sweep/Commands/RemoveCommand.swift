import ArgumentParser
import Foundation
import SweepCore

struct RemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Scan and safely remove an application and its leftovers."
    )

    @Argument(help: "Application name, path to .app, or bundle identifier.")
    var target: String

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

    func run() throws {
        // 1. Resolve target
        let resolver = AppResolver()
        let app = try resolver.resolve(target: target)

        // Safety check: protect sealed core Apple system applications
        if app.isSystemApp || SafetyGuard.isProtectedSystemApp(bundleIdentifier: app.bundleIdentifier, bundleURL: app.bundleURL) {
            throw SweepError.protectedSystemComponent("Target '\(app.bundleName)' (\(app.bundleIdentifier)) is a sealed macOS system-protected application.")
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
                print(Terminal.colorize("\n🔒 Administrator privileges (sudo) required for this uninstallation.", .boldYellow))
                print(Terminal.dim("Please enter your password if prompted by macOS.\n"))
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
}
