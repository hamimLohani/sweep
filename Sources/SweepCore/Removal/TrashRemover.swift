import Foundation

public struct RemovalItemResult {
    public let url: URL
    public let success: Bool
    public let trashURL: URL?
    public let errorMessage: String?
}

public struct RemovalExecutionResult {
    public let successfulItems: [RemovalItemResult]
    public let failedItems: [RemovalItemResult]
    public let record: RemovalRecord

    public var isCompleteSuccess: Bool {
        return failedItems.isEmpty
    }
}

public final class TrashRemover {
    private let fileManager: FileManager
    private let safetyGuard: SafetyGuard
    private let historyLogger: HistoryLogger
    private let privilegeHandler: PrivilegeHandling
    private let processManager: ProcessManager

    public init(
        fileManager: FileManager = .default,
        safetyGuard: SafetyGuard? = nil,
        historyLogger: HistoryLogger? = nil,
        privilegeHandler: PrivilegeHandling = PrivilegeHandler.shared,
        processManager: ProcessManager = .shared
    ) {
        self.fileManager = fileManager
        self.safetyGuard = safetyGuard ?? SafetyGuard(fileManager: fileManager)
        self.historyLogger = historyLogger ?? HistoryLogger(fileManager: fileManager)
        self.privilegeHandler = privilegeHandler
        self.processManager = processManager
    }

    private struct Target {
        let url: URL
        let category: String
        let sizeBytes: Int64
        let requiresPrivilege: Bool
    }

    /// Executes the application removal plan item by item with defense-in-depth safety checks and audit logging
    public func execute(
        plan: RemovalPlan,
        onItemWillDelete: ((URL, String) -> Void)? = nil
    ) throws -> RemovalExecutionResult {
        var targets: [Target] = [
            Target(
                url: plan.appInfo.bundleURL,
                category: "Application Bundle",
                sizeBytes: plan.appInfo.bundleSizeBytes,
                requiresPrivilege: plan.appInfo.bundleURL.path.hasPrefix("/Applications") && !privilegeHandler.canWrite(to: plan.appInfo.bundleURL)
            )
        ]

        for item in plan.selectedItems {
            targets.append(Target(
                url: item.url,
                category: item.category,
                sizeBytes: item.sizeBytes,
                requiresPrivilege: item.requiresPrivilege
            ))
        }

        let execution = executeTargets(
            targets,
            appInfo: plan.appInfo,
            isPermanent: plan.isPermanent,
            dryRun: plan.dryRun,
            onItemWillDelete: onItemWillDelete
        )

        let record = RemovalRecord(
            bundleIdentifier: plan.appInfo.bundleIdentifier,
            appName: plan.appInfo.bundleName,
            appVersion: plan.appInfo.version,
            isPermanent: plan.isPermanent,
            totalSizeBytes: plan.totalSizeBytes,
            items: execution.records
        )

        if !plan.dryRun && !execution.records.isEmpty {
            try? historyLogger.recordRemoval(record)
        }

        return RemovalExecutionResult(
            successfulItems: execution.successful,
            failedItems: execution.failed,
            record: record
        )
    }

    /// Executes a macOS package removal plan: removes selected package files/leftovers,
    /// prunes empty package directories, and forgets the receipt via `pkgutil --forget`.
    public func executePackageRemoval(
        plan: PackageRemovalPlan,
        receiptManager: ReceiptReading = ReceiptReader.shared,
        onItemWillDelete: ((URL, String) -> Void)? = nil
    ) throws -> PackageRemovalExecutionResult {
        if plan.packageInfo.isProtectedSystemPackage ||
           SafetyGuard.isProtectedSystemPackage(packageID: plan.packageInfo.packageIdentifier) {
            throw SweepError.protectedSystemComponent(
                "Package '\(plan.packageInfo.packageIdentifier)' is a core macOS system package and cannot be uninstalled."
            )
        }

        let targets = plan.selectedItems.map { item in
            Target(
                url: item.url,
                category: item.category,
                sizeBytes: item.sizeBytes,
                requiresPrivilege: item.requiresPrivilege
            )
        }

        let execution = executeTargets(
            targets,
            appInfo: nil,
            isPermanent: plan.isPermanent,
            dryRun: plan.dryRun,
            onItemWillDelete: onItemWillDelete
        )

        var prunedDirectories: [URL] = []
        var receiptForgotten = false
        var receiptForgetError: String?

        if !plan.dryRun {
            prunedDirectories = pruneEmptyDirectories(plan.candidateEmptyDirectories)

            if !plan.keepReceipt && execution.failed.isEmpty {
                do {
                    try receiptManager.forgetPackage(plan.packageInfo.packageIdentifier)
                    receiptForgotten = true
                } catch {
                    receiptForgetError = error.localizedDescription
                }
            }
        }

        let record = RemovalRecord(
            bundleIdentifier: plan.packageInfo.packageIdentifier,
            appName: "\(plan.packageInfo.displayName) (Package)",
            appVersion: plan.packageInfo.version,
            isPermanent: plan.isPermanent,
            totalSizeBytes: plan.totalSizeBytes,
            items: execution.records,
            forgottenPackageID: receiptForgotten ? plan.packageInfo.packageIdentifier : nil
        )

        if !plan.dryRun && (!execution.records.isEmpty || receiptForgotten) {
            try? historyLogger.recordRemoval(record)
        }

        return PackageRemovalExecutionResult(
            successfulItems: execution.successful,
            failedItems: execution.failed,
            prunedDirectories: prunedDirectories,
            receiptForgotten: receiptForgotten,
            receiptForgetError: receiptForgetError,
            record: record
        )
    }

    // MARK: - Shared Removal Execution

    private func executeTargets(
        _ targets: [Target],
        appInfo: AppInfo?,
        isPermanent: Bool,
        dryRun: Bool,
        onItemWillDelete: ((URL, String) -> Void)?
    ) -> (successful: [RemovalItemResult], failed: [RemovalItemResult], records: [RemovalItemRecord]) {
        var itemRecords: [RemovalItemRecord] = []
        var successful: [RemovalItemResult] = []
        var failed: [RemovalItemResult] = []

        for target in targets {
            let itemURL = target.url

            // Re-validate against safety invariants immediately before taking action
            do {
                try safetyGuard.validate(itemURL: itemURL, for: appInfo)
            } catch {
                failed.append(RemovalItemResult(
                    url: itemURL,
                    success: false,
                    trashURL: nil,
                    errorMessage: "Safety check rejected: \(error.localizedDescription)"
                ))
                continue
            }

            // Notify user of the exact deleting file path BEFORE deletion
            onItemWillDelete?(itemURL, target.category)

            if dryRun {
                successful.append(RemovalItemResult(url: itemURL, success: true, trashURL: nil, errorMessage: nil))
                continue
            }

            // If item is a launch agent or daemon, unload it first
            if itemURL.path.contains("LaunchAgents") || itemURL.path.contains("LaunchDaemons") {
                let isDaemon = itemURL.path.contains("LaunchDaemons")
                _ = processManager.unloadLaunchAgentOrDaemon(at: itemURL, isDaemon: isDaemon)
            }

            var trashResultURL: NSURL?
            var deletionSucceeded = false
            var errorDetails: String?

            do {
                if (target.requiresPrivilege || !privilegeHandler.canWrite(to: itemURL)) && !privilegeHandler.isRoot {
                    try privilegeHandler.removeWithPrivilege(at: itemURL)
                    deletionSucceeded = true
                } else if isPermanent {
                    try fileManager.removeItem(at: itemURL)
                    deletionSucceeded = true
                } else {
                    do {
                        try fileManager.trashItem(at: itemURL, resultingItemURL: &trashResultURL)
                        deletionSucceeded = true
                    } catch {
                        var st = stat()
                        let isSymlink = lstat(itemURL.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
                        if isSymlink {
                            try fileManager.removeItem(at: itemURL)
                            deletionSucceeded = true
                        } else if !privilegeHandler.canWrite(to: itemURL) || (error as NSError).domain == NSCocoaErrorDomain {
                            try privilegeHandler.authenticateIfNeeded()
                            try privilegeHandler.removeWithPrivilege(at: itemURL)
                            deletionSucceeded = true
                        } else {
                            throw error
                        }
                    }
                }
            } catch {
                deletionSucceeded = false
                errorDetails = error.localizedDescription
            }

            if deletionSucceeded {
                let trashPath = (trashResultURL as URL?)?.path
                successful.append(RemovalItemResult(url: itemURL, success: true, trashURL: trashResultURL as URL?, errorMessage: nil))
                itemRecords.append(RemovalItemRecord(
                    originalPath: itemURL.path,
                    trashPath: trashPath,
                    category: target.category,
                    sizeBytes: target.sizeBytes
                ))
            } else {
                failed.append(RemovalItemResult(url: itemURL, success: false, trashURL: nil, errorMessage: errorDetails))
            }
        }

        return (successful, failed, itemRecords)
    }

    private func pruneEmptyDirectories(_ directories: [URL]) -> [URL] {
        var pruned: [URL] = []
        let sorted = directories.sorted { $0.pathComponents.count > $1.pathComponents.count }

        for dirURL in sorted {
            do {
                try safetyGuard.validate(itemURL: dirURL)
            } catch {
                continue
            }

            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: dirURL.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            guard let contents = try? fileManager.contentsOfDirectory(atPath: dirURL.path), contents.isEmpty else {
                continue
            }

            do {
                if !privilegeHandler.canWrite(to: dirURL) && !privilegeHandler.isRoot {
                    try privilegeHandler.removeWithPrivilege(at: dirURL)
                } else {
                    try fileManager.removeItem(at: dirURL)
                }
                pruned.append(dirURL)
            } catch {
                continue
            }
        }

        return pruned
    }
}
