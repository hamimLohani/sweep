import ArgumentParser
import Foundation
import SweepCore

struct PkgCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pkg",
        abstract: "List, scan, and uninstall Homebrew packages and macOS .pkg receipts.",
        discussion: """
        Unified package management supporting both Homebrew packages (formulae & casks)
        and macOS Installer receipts (pkgutil). You can also use 'sweep brew' directly
        for Homebrew-only operations.

        EXAMPLES:
          sweep pkg list
          sweep pkg list --brew
          sweep pkg list --receipts
          sweep pkg scan bat
          sweep pkg scan org.wireshark.ChmodBPF.pkg
          sweep pkg remove neovide-app --dry-run
        """,
        subcommands: [
            PkgListCommand.self,
            PkgScanCommand.self,
            PkgRemoveCommand.self
        ]
    )
}

struct UnifiedPkgEntry: Codable {
    let identifier: String
    let source: String
    let version: String
    let location: String
}

struct PkgListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List installed Homebrew packages and/or macOS .pkg receipts."
    )

    @Flag(name: [.short, .long], help: "List Homebrew packages (formulae & casks) only.")
    var brew: Bool = false

    @Flag(name: [.short, .long], help: "List macOS Installer (.pkg) receipts only.")
    var receipts: Bool = false

    @Flag(name: [.short, .long], help: "Include Apple system and App Store .pkg receipts (com.apple.*).")
    var all: Bool = false

    @Option(name: [.short, .long], help: "Filter packages by identifier, name, or filename.")
    var filter: String?

    @Flag(name: .long, help: "Output results in JSON format.")
    var json: Bool = false

    func run() throws {
        if brew && receipts {
            throw SweepError.general("Specify at most one of --brew or --receipts (omit both to show all).")
        }

        let includeBrew = !receipts
        let includeReceipts = !brew

        var entries: [UnifiedPkgEntry] = []

        if includeBrew {
            let hbReader = HomebrewReader.shared
            if hbReader.isAvailable() {
                let hbPkgs = try HomebrewResolver(reader: hbReader).listInstalledPackages(filter: filter)
                for p in hbPkgs {
                    entries.append(UnifiedPkgEntry(
                        identifier: p.fullName,
                        source: "brew-\(p.kind.rawValue)",
                        version: p.version,
                        location: p.tap
                    ))
                }
            } else if brew {
                throw SweepError.general("Homebrew (brew) is not installed or not found in PATH.")
            }
        }

        if includeReceipts {
            let pkgReceipts = PackageResolver().listInstalledPackages(includeApple: all, filter: filter)
            for r in pkgReceipts {
                entries.append(UnifiedPkgEntry(
                    identifier: r.packageIdentifier,
                    source: "pkg-receipt",
                    version: r.version ?? "-",
                    location: r.baseURL.path
                ))
            }
        }

        if json {
            let data = try Formatters.jsonEncoder().encode(entries)
            if let output = String(data: data, encoding: .utf8) {
                print(output)
            }
            return
        }

        guard !entries.isEmpty else {
            print(Terminal.colorize("No matching packages found.", .yellow))
            return
        }

        print(Terminal.bold("Installed Packages (\(entries.count) found):"))
        print(Terminal.dim(String(repeating: "─", count: 98)))

        let maxIDLen = min(max(entries.map { $0.identifier.count }.max() ?? 30, 24), 44)
        let maxVerLen = min(max(entries.map { $0.version.count }.max() ?? 10, 8), 16)
        let maxLocLen = min(max(entries.map { $0.location.count }.max() ?? 18, 16), 24)

        let header = "Package".padding(toLength: maxIDLen, withPad: " ", startingAt: 0) + "  " +
                     "Source".padding(toLength: 12, withPad: " ", startingAt: 0) + "  " +
                     "Version".padding(toLength: maxVerLen, withPad: " ", startingAt: 0) + "  " +
                     "Location / Tap".padding(toLength: maxLocLen, withPad: " ", startingAt: 0)
        print(Terminal.bold(header))
        print(Terminal.dim(String(repeating: "─", count: 98)))

        for e in entries {
            let idCol = truncate(e.identifier, to: maxIDLen).padding(toLength: maxIDLen, withPad: " ", startingAt: 0)
            let srcCol = e.source.padding(toLength: 12, withPad: " ", startingAt: 0)
            let verCol = truncate(e.version, to: maxVerLen).padding(toLength: maxVerLen, withPad: " ", startingAt: 0)
            let locCol = truncate(e.location, to: maxLocLen).padding(toLength: maxLocLen, withPad: " ", startingAt: 0)
            print("\(idCol)  \(srcCol)  \(verCol)  \(locCol)")
        }

        print(Terminal.dim(String(repeating: "─", count: 98)))
        print(Terminal.bold("Total: ") + "\(entries.count) packages")
        if includeReceipts && !all {
            print(Terminal.dim("Tip: Use '--brew' for Homebrew only, '--receipts' for .pkg receipts, or '--all' to include Apple receipts."))
        }
    }

    private func truncate(_ value: String, to maxLen: Int) -> String {
        guard value.count > maxLen, maxLen > 1 else { return value }
        return String(value.prefix(maxLen - 1)) + "…"
    }
}

private enum ResolvedPkgTarget {
    case homebrew(HomebrewPackageInfo)
    case receipt(PackageInfo)
}

private func resolveUnifiedPackage(
    target: String,
    brewOnly: Bool,
    receiptsOnly: Bool,
    formulaOnly: Bool,
    caskOnly: Bool
) throws -> ResolvedPkgTarget {
    if brewOnly && receiptsOnly {
        throw SweepError.general("Cannot specify both --brew and --receipts.")
    }
    let preferredKind = try BrewCommandHelpers.resolveKindFlag(formula: formulaOnly, cask: caskOnly)

    if brewOnly || preferredKind != nil {
        let hbPkg = try HomebrewResolver().resolve(target: target, preferredKind: preferredKind)
        return .homebrew(hbPkg)
    }
    if receiptsOnly {
        let receiptPkg = try PackageResolver().resolve(target: target)
        return .receipt(receiptPkg)
    }

    // Unified resolution across Homebrew and .pkg receipts
    var hbMatch: HomebrewPackageInfo?
    var hbAmbiguous: SweepError?
    if HomebrewReader.shared.isAvailable() {
        do {
            hbMatch = try HomebrewResolver().resolve(target: target)
        } catch let err as SweepError {
            if case .ambiguousPackage = err { hbAmbiguous = err }
        }
    }

    var receiptMatch: PackageInfo?
    var receiptAmbiguous: SweepError?
    do {
        receiptMatch = try PackageResolver().resolve(target: target)
    } catch let err as SweepError {
        if case .ambiguousPackage = err { receiptAmbiguous = err }
    }

    if let hb = hbMatch, let rec = receiptMatch {
        let lower = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hbExact = hb.fullName.lowercased() == lower || hb.name.lowercased() == lower
        let recExact = rec.packageIdentifier.lowercased() == lower

        if hbExact && !recExact { return .homebrew(hb) }
        if recExact && !hbExact { return .receipt(rec) }

        throw SweepError.ambiguousPackage(target, [
            "\(hb.fullName) (Homebrew \(hb.kind.rawValue) — pass --brew)",
            "\(rec.packageIdentifier) (.pkg receipt — pass --receipts)"
        ])
    }

    if let hb = hbMatch {
        if let recErr = receiptAmbiguous {
            // Exact Homebrew match wins over vague receipt substring ambiguity
            let lower = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if hb.fullName.lowercased() == lower || hb.name.lowercased() == lower {
                return .homebrew(hb)
            }
            throw recErr
        }
        return .homebrew(hb)
    }

    if let rec = receiptMatch {
        if let hbErr = hbAmbiguous {
            let lower = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if rec.packageIdentifier.lowercased() == lower {
                return .receipt(rec)
            }
            throw hbErr
        }
        return .receipt(rec)
    }

    if let hbErr = hbAmbiguous { throw hbErr }
    if let recErr = receiptAmbiguous { throw recErr }
    throw SweepError.packageNotFound(target)
}

struct PkgScanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Scan a Homebrew package or .pkg receipt for files, caches, and leftovers."
    )

    @Argument(help: "Homebrew formula/cask name or .pkg receipt identifier.")
    var target: String

    @Flag(name: [.short, .long], help: "Resolve target as a Homebrew package.")
    var brew: Bool = false

    @Flag(name: [.short, .long], help: "Resolve target as a macOS .pkg receipt.")
    var receipts: Bool = false

    @Flag(name: .long, help: "Only match Homebrew formulae.")
    var formula: Bool = false

    @Flag(name: .long, help: "Only match Homebrew casks.")
    var cask: Bool = false

    @Flag(name: .long, help: "For .pkg receipts, expand collapsed bundles/directories to list every file.")
    var files: Bool = false

    @Flag(name: .long, help: "Output results in JSON format.")
    var json: Bool = false

    func run() throws {
        let resolved = try resolveUnifiedPackage(
            target: target,
            brewOnly: brew,
            receiptsOnly: receipts,
            formulaOnly: formula,
            caskOnly: cask
        )

        switch resolved {
        case .homebrew(let hbPkg):
            try BrewCommandHelpers.runScan(for: hbPkg, json: json)
        case .receipt(let pkg):
            try runReceiptScan(pkg: pkg)
        }
    }

    private func runReceiptScan(pkg: PackageInfo) throws {
        let scanner = PackageScanner()
        let result = try scanner.scan(packageInfo: pkg, expandCollapsedDirectories: files)

        if json {
            let data = try Formatters.jsonEncoder().encode(result)
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
        abstract: "Safely uninstall a Homebrew package or macOS .pkg receipt and clean its leftovers."
    )

    @Argument(help: "Homebrew formula/cask name or .pkg receipt identifier.")
    var target: String

    @Flag(name: [.short, .long], help: "Resolve target as a Homebrew package.")
    var brew: Bool = false

    @Flag(name: [.short, .long], help: "Resolve target as a macOS .pkg receipt.")
    var receipts: Bool = false

    @Flag(name: .long, help: "Only match Homebrew formulae.")
    var formula: Bool = false

    @Flag(name: .long, help: "Only match Homebrew casks.")
    var cask: Bool = false

    @Flag(name: .long, help: "Perform a trial run without modifying/deleting files.")
    var dryRun: Bool = false

    @Flag(name: [.short, .long], help: "Skip interactive confirmation and proceed.")
    var yes: Bool = false

    @Flag(name: .long, help: "Permanently delete leftover files instead of moving user-writable items to the Trash.")
    var permanent: Bool = false

    @Flag(name: .long, help: "Include low-confidence runtime leftovers in cleanup candidates.")
    var includeLowConfidence: Bool = false

    @Flag(name: .long, help: "For .pkg receipts, remove files without running 'pkgutil --forget'.")
    var keepReceipt: Bool = false

    @Flag(name: .long, help: "For Homebrew formulae, uninstall even if other packages depend on it.")
    var ignoreDependencies: Bool = false

    @Flag(name: .long, help: "For Homebrew packages, pass --force to 'brew uninstall'.")
    var force: Bool = false

    @Flag(name: .long, help: "For Homebrew packages, run 'brew autoremove' afterwards.")
    var autoremove: Bool = false

    @Flag(name: .long, help: "For Homebrew packages, uninstall via brew without cleaning leftovers/caches.")
    var noLeftovers: Bool = false

    @Flag(name: .long, help: "Output results in JSON format.")
    var json: Bool = false

    func run() throws {
        let resolved = try resolveUnifiedPackage(
            target: target,
            brewOnly: brew,
            receiptsOnly: receipts,
            formulaOnly: formula,
            caskOnly: cask
        )

        switch resolved {
        case .homebrew(let hbPkg):
            try BrewCommandHelpers.runRemove(
                for: hbPkg,
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
        case .receipt(let pkg):
            try runReceiptRemove(pkg: pkg)
        }
    }

    private func runReceiptRemove(pkg: PackageInfo) throws {
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
            let data = try Formatters.jsonEncoder().encode(result.record)
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
