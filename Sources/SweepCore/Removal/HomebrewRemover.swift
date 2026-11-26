import Foundation

public final class HomebrewRemover {
    private let fileManager: FileManager
    private let reader: HomebrewReading
    private let trashRemover: TrashRemover
    private let historyLogger: HistoryLogger

    public init(
        fileManager: FileManager = .default,
        reader: HomebrewReading = HomebrewReader.shared,
        safetyGuard: SafetyGuard? = nil,
        historyLogger: HistoryLogger? = nil,
        privilegeHandler: PrivilegeHandling = PrivilegeHandler.shared,
        processManager: ProcessManager = .shared
    ) {
        self.fileManager = fileManager
        self.reader = reader
        let resolvedHistory = historyLogger ?? HistoryLogger(fileManager: fileManager)
        self.historyLogger = resolvedHistory
        self.trashRemover = TrashRemover(
            fileManager: fileManager,
            safetyGuard: safetyGuard,
            historyLogger: resolvedHistory,
            privilegeHandler: privilegeHandler,
            processManager: processManager
        )
    }

    public func execute(
        plan: HomebrewRemovalPlan,
        onStep: ((String) -> Void)? = nil,
        onItemWillDelete: ((URL, String) -> Void)? = nil
    ) throws -> HomebrewRemovalExecutionResult {
        let pkg = plan.packageInfo

        // Safety check: refuse uninstalling formulae still required by other packages unless --ignore-dependencies or --force
        if pkg.kind == .formula && !pkg.requiredBy.isEmpty && !plan.ignoreDependencies && !plan.force {
            throw SweepError.general(
                "Formula '\(pkg.name)' is required by: \(pkg.requiredBy.joined(separator: ", ")). Pass --ignore-dependencies to uninstall anyway."
            )
        }

        var serviceStopped = false
        var brewUninstalled = false
        var brewOutput = ""
        var autoremoveExecuted = false
        var autoremoveOutput: String?

        // 1. Stop running brew service if active
        if pkg.serviceRunning, let serviceName = pkg.serviceName {
            if plan.dryRun {
                onStep?("[WOULD STOP] brew services stop \(serviceName)")
            } else {
                onStep?("Stopping Homebrew service '\(serviceName)'...")
                try? reader.stopService(serviceName)
                serviceStopped = true
            }
        }

        // 2. Uninstall formula/cask via Homebrew
        if plan.dryRun {
            let typeFlag = pkg.kind == .cask ? "--cask" : "--formula"
            var cmd = "brew uninstall \(typeFlag)"
            if plan.ignoreDependencies && pkg.kind == .formula { cmd += " --ignore-dependencies" }
            if plan.force { cmd += " --force" }
            cmd += " \(pkg.fullName)"
            onStep?("[WOULD RUN] \(cmd)")
            brewUninstalled = true
        } else {
            brewOutput = try reader.uninstall(
                package: pkg,
                ignoreDependencies: plan.ignoreDependencies,
                force: plan.force
            )
            brewUninstalled = true
        }

        // 3. Clean selected leftover, zap, config, and Homebrew download cache items
        let cleanup = trashRemover.executeItems(
            plan.selectedCleanupItems,
            appInfo: nil,
            isPermanent: plan.isPermanent,
            dryRun: plan.dryRun,
            onItemWillDelete: onItemWillDelete
        )

        // 4. Prune orphaned dependencies if requested
        if plan.autoremove {
            if plan.dryRun {
                let preview = (try? reader.autoremove(dryRun: true)) ?? ""
                autoremoveOutput = preview
                onStep?("[WOULD RUN] brew autoremove")
            } else {
                autoremoveOutput = try? reader.autoremove(dryRun: false)
                autoremoveExecuted = true
            }
        }

        // 5. Write audit log entry
        var auditItems = cleanup.records
        if !plan.dryRun, let rootURL = pkg.cellarOrCaskroomURL {
            auditItems.insert(
                RemovalItemRecord(
                    originalPath: rootURL.path,
                    trashPath: nil,
                    category: "Homebrew \(pkg.kind.displayLabel)",
                    sizeBytes: plan.cellarSizeBytes
                ),
                at: 0
            )
        }

        let record = RemovalRecord(
            bundleIdentifier: "homebrew.\(pkg.kind.rawValue).\(pkg.fullName)",
            appName: "\(pkg.primaryDisplayName) (Homebrew \(pkg.kind.displayLabel))",
            appVersion: pkg.version,
            isPermanent: plan.isPermanent,
            totalSizeBytes: plan.totalSizeBytes,
            items: auditItems
        )

        if !plan.dryRun && brewUninstalled {
            try? historyLogger.recordRemoval(record)
        }

        return HomebrewRemovalExecutionResult(
            serviceStopped: serviceStopped,
            brewUninstalled: brewUninstalled,
            brewOutput: brewOutput,
            autoremoveExecuted: autoremoveExecuted,
            autoremoveOutput: autoremoveOutput,
            successfulCleanupItems: cleanup.successful,
            failedCleanupItems: cleanup.failed,
            record: record
        )
    }
}
