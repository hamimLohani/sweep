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
    private let privilegeHandler: PrivilegeHandler
    private let processManager: ProcessManager

    public init(
        fileManager: FileManager = .default,
        safetyGuard: SafetyGuard? = nil,
        historyLogger: HistoryLogger? = nil,
        privilegeHandler: PrivilegeHandler = .shared,
        processManager: ProcessManager = .shared
    ) {
        self.fileManager = fileManager
        self.safetyGuard = safetyGuard ?? SafetyGuard(fileManager: fileManager)
        self.historyLogger = historyLogger ?? HistoryLogger(fileManager: fileManager)
        self.privilegeHandler = privilegeHandler
        self.processManager = processManager
    }

    /// Executes the removal plan item by item with defense-in-depth safety checks and audit logging
    public func execute(
        plan: RemovalPlan,
        onItemWillDelete: ((URL, String) -> Void)? = nil
    ) throws -> RemovalExecutionResult {
        var itemRecords: [RemovalItemRecord] = []
        var successful: [RemovalItemResult] = []
        var failed: [RemovalItemResult] = []

        // 1. Prepare target list: [app bundle] + selected leftover items
        struct Target {
            let url: URL
            let category: String
            let sizeBytes: Int64
            let requiresPrivilege: Bool
        }

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

        // 2. Iterate through each target
        for target in targets {
            let itemURL = target.url

            // Re-validate against safety invariants immediately before taking action
            do {
                try safetyGuard.validate(itemURL: itemURL, for: plan.appInfo)
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

            // If dry run, record success without filesystem modification
            if plan.dryRun {
                successful.append(RemovalItemResult(url: itemURL, success: true, trashURL: nil, errorMessage: nil))
                continue
            }

            // If item is a launch agent or daemon, unload it first
            if itemURL.path.contains("LaunchAgents") || itemURL.path.contains("LaunchDaemons") {
                let isDaemon = itemURL.path.contains("LaunchDaemons")
                _ = processManager.unloadLaunchAgentOrDaemon(at: itemURL, isDaemon: isDaemon)
            }

            // Execute deletion
            var trashResultURL: NSURL?
            var deletionSucceeded = false
            var errorDetails: String?

            do {
                if (target.requiresPrivilege || !privilegeHandler.canWrite(to: itemURL)) && !privilegeHandler.isRoot {
                    // System-owned file requiring sudo
                    try privilegeHandler.removeWithPrivilege(at: itemURL)
                    deletionSucceeded = true
                } else if plan.isPermanent {
                    // Permanent deletion via rm
                    try fileManager.removeItem(at: itemURL)
                    deletionSucceeded = true
                } else {
                    // Safe move to Trash
                    do {
                        try fileManager.trashItem(at: itemURL, resultingItemURL: &trashResultURL)
                        deletionSucceeded = true
                    } catch {
                        // If moving to trash failed due to permission/ownership, attempt privileged removal
                        if !privilegeHandler.canWrite(to: itemURL) || (error as NSError).domain == NSCocoaErrorDomain {
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

        // 3. Record removal transaction in history manifest
        let record = RemovalRecord(
            bundleIdentifier: plan.appInfo.bundleIdentifier,
            appName: plan.appInfo.bundleName,
            appVersion: plan.appInfo.version,
            isPermanent: plan.isPermanent,
            totalSizeBytes: plan.totalSizeBytes,
            items: itemRecords
        )

        if !plan.dryRun && !itemRecords.isEmpty {
            try? historyLogger.recordRemoval(record)
        }

        return RemovalExecutionResult(successfulItems: successful, failedItems: failed, record: record)
    }
}
