import ArgumentParser
import Foundation
import SweepCore

struct PkgCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pkg",
        abstract: "List, scan, and uninstall macOS installer packages (.pkg receipts).",
        discussion: """
        Inspects and removes macOS installer packages registered in the receipt database
        (pkgutil), safely skipping files shared with other packages, pruning empty
        directories, cleaning associated leftovers, and forgetting package receipts.

        EXAMPLES:
          sweep pkg list
          sweep pkg list --all
          sweep pkg scan org.wireshark.ChmodBPF.pkg
          sweep pkg remove org.wireshark.ChmodBPF.pkg --dry-run
        """,
        subcommands: [
            PkgListCommand.self,
            PkgScanCommand.self,
            PkgRemoveCommand.self
        ]
    )
}

struct PkgListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List installed macOS installer packages (.pkg receipts)."
    )

    @Flag(name: [.short, .long], help: "Include Apple system and App Store packages (com.apple.*).")
    var all: Bool = false

    @Option(name: [.short, .long], help: "Filter packages by identifier, filename, or name.")
    var filter: String?

    @Flag(name: .long, help: "Output results in JSON format.")
    var json: Bool = false

    func run() throws {
        let resolver = PackageResolver()
        let packages = resolver.listInstalledPackages(includeApple: all, filter: filter)

        if json {
            let encoder = Formatters.jsonEncoder()
            let data = try encoder.encode(packages)
            if let output = String(data: data, encoding: .utf8) {
                print(output)
            }
            return
        }

        guard !packages.isEmpty else {
            let scopeNote = all ? "" : " (third-party)"
            print(Terminal.colorize("No\(scopeNote) installer packages found.", .yellow))
            if !all {
                print(Terminal.dim("Use --all to include Apple packages (com.apple.*)."))
            }
            return
        }

        let scopeLabel = all ? "All" : "Third-Party"
        print(Terminal.bold("Installed \(scopeLabel) Packages (\(packages.count) found):"))
        print(Terminal.dim(String(repeating: "─", count: 96)))

        let maxIDLen = min(max(packages.map { $0.packageIdentifier.count }.max() ?? 32, 26), 46)
        let maxVerLen = min(max(packages.map { ($0.version ?? "-").count }.max() ?? 10, 8), 16)
        let maxLocLen = min(max(packages.map { $0.baseURL.path.count }.max() ?? 16, 16), 28)

        let header = "Package Identifier".padding(toLength: maxIDLen, withPad: " ", startingAt: 0) + "  " +
                     "Version".padding(toLength: maxVerLen, withPad: " ", startingAt: 0) + "  " +
                     "Install Root".padding(toLength: maxLocLen, withPad: " ", startingAt: 0)
        print(Terminal.bold(header))
        print(Terminal.dim(String(repeating: "─", count: 96)))

        for pkg in packages {
            let rawID = truncate(pkg.packageIdentifier, to: maxIDLen)
            let rawVer = truncate(pkg.version ?? "-", to: maxVerLen)
            let rawLoc = truncate(pkg.baseURL.path, to: maxLocLen)

            let idCol = rawID.padding(toLength: maxIDLen, withPad: " ", startingAt: 0)
            let verCol = rawVer.padding(toLength: maxVerLen, withPad: " ", startingAt: 0)
            let locCol = rawLoc.padding(toLength: maxLocLen, withPad: " ", startingAt: 0)

            print("\(idCol)  \(verCol)  \(locCol)")
        }

        print(Terminal.dim(String(repeating: "─", count: 96)))
        print(Terminal.bold("Total: ") + "\(packages.count) packages")
        if !all {
            print(Terminal.dim("Tip: Use 'sweep pkg list --all' to include Apple packages (com.apple.*)."))
        }
    }

    private func truncate(_ value: String, to maxLen: Int) -> String {
        guard value.count > maxLen, maxLen > 1 else { return value }
        return String(value.prefix(maxLen - 1)) + "…"
    }
}

struct PkgScanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Scan an installed package receipt for owned files, shared files, and leftovers."
    )

    @Argument(help: "Package identifier, installer filename, or unique name.")
    var target: String

    @Flag(name: .long, help: "Expand collapsed bundles/directories to list every individual installed file.")
    var files: Bool = false

    @Flag(name: .long, help: "Output results in JSON format.")
    var json: Bool = false

    func run() throws {
        let resolver = PackageResolver()
        let pkg = try resolver.resolve(target: target)

        let scanner = PackageScanner()
        let result = try scanner.scan(packageInfo: pkg, expandCollapsedDirectories: files)

        if json {
            let encoder = Formatters.jsonEncoder()
            let data = try encoder.encode(result)
            if let output = String(data: data, encoding: .utf8) {
                print(output)
            }
            return
        }

        Formatters.printPackageSummary(result.packageInfo)

        if !result.missingFilePaths.isEmpty {
            print(Terminal.dim("Receipt Info: ") + "\(result.missingFilePaths.count) file(s) listed in receipt are already absent from disk.")
        }

        if result.items.isEmpty && result.sharedFiles.isEmpty {
            print(Terminal.colorize("No removable files or leftovers found on disk for this package.", .yellow))
            if !pkg.isProtectedSystemPackage {
                print(Terminal.dim("\n💡 To forget the orphaned package receipt, run: ") + Terminal.bold("sweep pkg remove \"\(pkg.packageIdentifier)\""))
            }
            return
        }

        if !result.items.isEmpty {
            print(Terminal.bold("Detected Package Items & Leftovers (\(result.items.count) items):"))
            print(Terminal.dim(String(repeating: "─", count: 70)))

            let grouped = result.groupedByCategory
            for category in grouped.keys.sorted() {
                let items = grouped[category] ?? []
                let catTotal = items.reduce(0) { $0 + $1.sizeBytes }
                print(Terminal.bold("\n📦 \(category)") + " " + Terminal.dim("(\(items.count) items, \(Terminal.formatBytes(catTotal)))"))

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

        if !result.sharedFiles.isEmpty {
            print("\n" + Terminal.colorize("🔒 Shared Files Preserved (\(result.sharedFiles.count) items owned by other packages):", .boldYellow))
            for shared in result.sharedFiles.prefix(10) {
                let owners = shared.sharedWithPackages.joined(separator: ", ")
                print("  • \(Formatters.formatPath(shared.url)) " + Terminal.dim("(shared with: \(owners))"))
            }
            if result.sharedFiles.count > 10 {
                print(Terminal.dim("  ... and \(result.sharedFiles.count - 10) more shared files that will NOT be deleted."))
            }
        }

        if !result.protectedSkippedPaths.isEmpty {
            print("\n" + Terminal.dim("🛡️  \(result.protectedSkippedPaths.count) path(s) in protected system domains were excluded by SafetyGuard."))
        }

        print(Terminal.dim("\n" + String(repeating: "─", count: 70)))
        print(Terminal.bold("Package Files Size: ") + Terminal.formatBytes(result.packageFilesSizeBytes))
        print(Terminal.bold("Leftovers Size:     ") + Terminal.colorize(Terminal.formatBytes(result.leftoversSizeBytes), .yellow))
        print(Terminal.bold("Total Disk Usage:   ") + Terminal.colorize(Terminal.formatBytes(result.totalSizeBytes), .boldCyan))

        if result.hasPrivilegedItems {
            print(Terminal.colorize("\n⚠️  Some items reside in system directories and will require administrator privileges to remove.", .boldYellow))
        }

        print(Terminal.dim("\n💡 This was a scan only. No files were modified or deleted."))

        if pkg.isProtectedSystemPackage {
            print(Terminal.colorize("   '\(pkg.packageIdentifier)' is a protected core macOS system package and cannot be uninstalled.", .yellow))
        } else {
            print(Terminal.dim("   To remove this package and forget its receipt, run: ") + Terminal.bold("sweep pkg remove \"\(pkg.packageIdentifier)\""))
        }
    }
}

struct PkgRemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Safely remove a macOS installer package, its leftovers, and forget its receipt."
    )

    @Argument(help: "Package identifier, installer filename, or unique name.")
    var target: String

    @Flag(name: .long, help: "Perform a trial run without moving/deleting files or forgetting the receipt.")
    var dryRun: Bool = false

    @Flag(name: [.short, .long], help: "Skip interactive confirmation and remove all discovered items.")
    var yes: Bool = false

    @Flag(name: .long, help: "Permanently delete files instead of moving user-writable items to the Trash (Caution).")
    var permanent: Bool = false

    @Flag(name: .long, help: "Include low-confidence runtime leftovers in the removal candidates.")
    var includeLowConfidence: Bool = false

    @Flag(name: .long, help: "Remove files and leftovers without forgetting the receipt via 'pkgutil --forget'.")
    var keepReceipt: Bool = false

    @Flag(name: .long, help: "Output results in JSON format.")
    var json: Bool = false

    func run() throws {
        let resolver = PackageResolver()
        let pkg = try resolver.resolve(target: target)

        if pkg.isProtectedSystemPackage || SafetyGuard.isProtectedSystemPackage(packageID: pkg.packageIdentifier) {
            throw SweepError.protectedSystemComponent(
                "Package '\(pkg.packageIdentifier)' is a protected core macOS system package and cannot be uninstalled."
            )
        }

        let scanner = PackageScanner()
        let scanResult = try scanner.scan(packageInfo: pkg)

        if !json {
            Formatters.printPackageSummary(pkg)
            if !scanResult.sharedFiles.isEmpty {
                print(Terminal.colorize("ℹ️  Preserving \(scanResult.sharedFiles.count) shared file(s) also referenced by other packages.", .yellow))
            }
        }

        // Quit any running .app bundles exclusively installed by this package
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
                    if !json {
                        print(Terminal.dim("Stopping '\(app.displayName)'..."))
                    }
                    guard processManager.quitApp(bundleIdentifier: app.bundleIdentifier) else {
                        throw SweepError.runningAppRefusedQuit(app.displayName)
                    }
                }
            }
        }

        let selectedItems: [LeftoverItem]
        if scanResult.items.isEmpty {
            selectedItems = []
            if keepReceipt {
                if !json {
                    print(Terminal.colorize("No removable files found on disk and --keep-receipt is set. Nothing to do.", .yellow))
                }
                return
            }
            if !json {
                print(Terminal.colorize("No removable files found on disk for '\(pkg.packageIdentifier)' (\(scanResult.missingFilePaths.count) receipt path(s) already absent).", .yellow))
            }
        } else {
            guard let picked = InteractiveChecklist.selectItems(
                candidates: scanResult.items,
                includeLowConfidence: includeLowConfidence,
                autoConfirm: yes || json
            ) else {
                print(Terminal.colorize("Removal cancelled by user.", .yellow))
                return
            }
            selectedItems = picked

            if selectedItems.isEmpty && keepReceipt {
                if !json {
                    print(Terminal.colorize("No items selected and --keep-receipt is set. Operation aborted.", .yellow))
                }
                return
            }
        }

        let plan = PackageRemovalPlan(
            packageInfo: pkg,
            selectedItems: selectedItems,
            candidateEmptyDirectories: scanResult.candidateEmptyDirectories,
            isPermanent: permanent,
            dryRun: dryRun,
            keepReceipt: keepReceipt
        )

        if dryRun && !json {
            let receiptMsg = keepReceipt ? "" : " and forget receipt '\(pkg.packageIdentifier)'"
            print(Terminal.colorize("\n[DRY RUN MODE] Simulating removal of \(plan.totalItemsCount) items (\(Terminal.formatBytes(plan.totalSizeBytes)))\(receiptMsg):", .boldCyan))
        }

        if !yes && !dryRun {
            let actionName = permanent ? "PERMANENTLY DELETE" : "remove"
            let warningColor = permanent ? TerminalColor.boldRed : TerminalColor.boldYellow
            let receiptClause = keepReceipt ? "" : " and forget receipt '\(pkg.packageIdentifier)'"
            let promptText: String
            if plan.totalItemsCount == 0 {
                promptText = "Forget orphaned package receipt '\(pkg.packageIdentifier)' via pkgutil --forget?"
            } else {
                promptText = "Are you sure you want to \(actionName) \(plan.totalItemsCount) items (\(Terminal.formatBytes(plan.totalSizeBytes)))\(receiptClause)?"
            }

            print("\n" + Terminal.colorize(promptText, warningColor) + " [y/N]: ", terminator: "")
            fflush(stdout)
            let confirm = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "n"
            guard confirm == "y" || confirm == "yes" else {
                print(Terminal.colorize("Operation aborted.", .yellow))
                return
            }
        }

        // Authenticate sudo upfront if forgetting receipt or removing privileged files
        let needsSudo = !keepReceipt || plan.hasPrivilegedItems || plan.selectedItems.contains { !PrivilegeHandler.shared.canWrite(to: $0.url) }
        if !dryRun && needsSudo {
            let privilegeHandler = PrivilegeHandler.shared
            if !privilegeHandler.isRoot {
                if !privilegeHandler.hasCachedSudo() && !json {
                    print(Terminal.colorize("\n🔒 Administrator privileges (sudo) required for package uninstallation.", .boldYellow))
                    print(Terminal.dim("Please enter your administrator password if prompted by macOS.\n"))
                }
                try privilegeHandler.authenticateIfNeeded()
            }
        }

        let remover = TrashRemover()
        let result = try remover.executePackageRemoval(plan: plan) { url, category in
            guard !json else { return }
            let actionPrefix = dryRun ? "[WOULD REMOVE]" : (permanent ? "[DELETING]" : "[TRASHING]")
            print(Terminal.colorize("\(actionPrefix) ", .cyan) + Terminal.bold(url.path) + Terminal.dim(" (\(category))"))
        }

        if dryRun && !keepReceipt && !json {
            print(Terminal.colorize("[WOULD FORGET] ", .cyan) + Terminal.bold(pkg.packageIdentifier) + Terminal.dim(" (pkgutil --forget)"))
        }

        if json {
            let encoder = Formatters.jsonEncoder()
            let data = try encoder.encode(result.record)
            if let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            return
        }

        print(Terminal.dim("\n" + String(repeating: "─", count: 70)))
        if dryRun {
            print(Terminal.colorize("✓ Dry run complete. No files or receipts were modified.", .boldGreen))
            return
        }

        if !result.prunedDirectories.isEmpty {
            print(Terminal.dim("  Pruned \(result.prunedDirectories.count) empty package directory(ies)."))
        }

        if result.isCompleteSuccess {
            if result.successfulItems.isEmpty && result.receiptForgotten {
                print(Terminal.colorize("✓ Forgot package receipt '\(pkg.packageIdentifier)'.", .boldGreen))
            } else {
                let verb = permanent ? "Permanently deleted" : "Removed"
                print(Terminal.colorize("✓ \(verb) \(result.successfulItems.count) items (\(Terminal.formatBytes(plan.totalSizeBytes))).", .boldGreen))
                if result.receiptForgotten {
                    print(Terminal.colorize("✓ Forgot package receipt '\(pkg.packageIdentifier)'.", .boldGreen))
                } else if keepReceipt {
                    print(Terminal.dim("  Package receipt kept (--keep-receipt)."))
                }
            }
            print(Terminal.dim("  Audit log written to ~/.config/sweep/history.json"))
        } else {
            print(Terminal.colorize("⚠️  Completed with some errors:", .boldYellow))
            print("  Successfully processed: \(result.successfulItems.count) items")
            print("  Failed to process:      \(result.failedItems.count) items")
            for failed in result.failedItems {
                print(Terminal.colorize("  ✖ \(failed.url.path): \(failed.errorMessage ?? "Permission error")", .red))
            }
            if let forgetErr = result.receiptForgetError {
                print(Terminal.colorize("  ✖ Receipt forget failed: \(forgetErr)", .red))
            } else if !keepReceipt && !result.failedItems.isEmpty {
                print(Terminal.colorize("  ℹ️  Package receipt was preserved because some files failed to remove.", .yellow))
            }
            throw SweepError.permissionDenied("Some package items could not be removed cleanly.")
        }
    }
}
