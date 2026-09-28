import Foundation

public struct CacheCleanItemResult {
    public let url: URL
    public let sizeBytes: Int64
    public let success: Bool
    public let errorMessage: String?
}

public struct CacheCleanExecutionResult {
    public let successfulItems: [CacheCleanItemResult]
    public let failedItems: [CacheCleanItemResult]
    public var totalFreedBytes: Int64 {
        successfulItems.reduce(0) { $0 + $1.sizeBytes }
    }
}

public final class CacheCleaner {
    private let fileManager: FileManager
    private let safetyGuard: SafetyGuard
    private let historyLogger: HistoryLogger
    private let privilegeHandler: PrivilegeHandler

    public init(
        fileManager: FileManager = .default,
        safetyGuard: SafetyGuard? = nil,
        historyLogger: HistoryLogger? = nil,
        privilegeHandler: PrivilegeHandler = .shared
    ) {
        self.fileManager = fileManager
        self.safetyGuard = safetyGuard ?? SafetyGuard(fileManager: fileManager)
        self.historyLogger = historyLogger ?? HistoryLogger(fileManager: fileManager)
        self.privilegeHandler = privilegeHandler
    }

    /// Cleans cache items with mandatory administrator privilege authentication
    public func clean(
        items: [LeftoverItem],
        appInfo: AppInfo,
        dryRun: Bool = false,
        onItemWillClean: ((URL, String, Int64) -> Void)? = nil
    ) throws -> CacheCleanExecutionResult {
        var successful: [CacheCleanItemResult] = []
        var failed: [CacheCleanItemResult] = []
        var itemRecords: [RemovalItemRecord] = []

        // If not a dry run, enforce sudo password authentication upfront as required
        if !dryRun && !items.isEmpty {
            try privilegeHandler.authenticateIfNeeded()
        }

        for item in items {
            let itemURL = item.url

            // Re-validate against safety invariants immediately before taking action
            do {
                try safetyGuard.validate(itemURL: itemURL, for: appInfo, isCacheOnly: true)
            } catch {
                failed.append(CacheCleanItemResult(
                    url: itemURL,
                    sizeBytes: item.sizeBytes,
                    success: false,
                    errorMessage: "Safety check rejected: \(error.localizedDescription)"
                ))
                continue
            }

            // Notify user of exact path being cleaned
            onItemWillClean?(itemURL, item.category, item.sizeBytes)

            if dryRun {
                successful.append(CacheCleanItemResult(url: itemURL, sizeBytes: item.sizeBytes, success: true, errorMessage: nil))
                continue
            }

            var deletionSucceeded = false
            var errorDetails: String?

            do {
                // Delete using privileged removal
                try privilegeHandler.removeWithPrivilege(at: itemURL)
                deletionSucceeded = true
            } catch {
                // Fallback to regular file removal if already permitted
                do {
                    try fileManager.removeItem(at: itemURL)
                    deletionSucceeded = true
                } catch let fileError {
                    deletionSucceeded = false
                    errorDetails = fileError.localizedDescription
                }
            }

            if deletionSucceeded {
                successful.append(CacheCleanItemResult(url: itemURL, sizeBytes: item.sizeBytes, success: true, errorMessage: nil))
                itemRecords.append(RemovalItemRecord(
                    originalPath: itemURL.path,
                    trashPath: nil,
                    category: item.category,
                    sizeBytes: item.sizeBytes
                ))
            } else {
                failed.append(CacheCleanItemResult(url: itemURL, sizeBytes: item.sizeBytes, success: false, errorMessage: errorDetails))
            }
        }

        if !dryRun && !itemRecords.isEmpty {
            let record = RemovalRecord(
                bundleIdentifier: appInfo.bundleIdentifier,
                appName: "\(appInfo.bundleName) (Cache Clean)",
                appVersion: appInfo.version,
                isPermanent: true,
                totalSizeBytes: successful.reduce(0) { $0 + $1.sizeBytes },
                items: itemRecords
            )
            try? historyLogger.recordRemoval(record)
        }

        return CacheCleanExecutionResult(successfulItems: successful, failedItems: failed)
    }
}
