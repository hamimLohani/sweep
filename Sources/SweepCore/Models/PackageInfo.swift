import Foundation

public struct PackageInfo: Codable, Equatable, Hashable {
    public let packageIdentifier: String
    public let version: String?
    public let volume: String
    public let installLocation: String
    public let installTime: Date?
    public let packageFileName: String?
    public let groups: [String]
    public let isApplePackage: Bool
    public let isProtectedSystemPackage: Bool

    public init(
        packageIdentifier: String,
        version: String?,
        volume: String = "/",
        installLocation: String = "/",
        installTime: Date? = nil,
        packageFileName: String? = nil,
        groups: [String] = [],
        isApplePackage: Bool? = nil,
        isProtectedSystemPackage: Bool? = nil
    ) {
        self.packageIdentifier = packageIdentifier
        self.version = version
        let normalizedVolume = volume.isEmpty ? "/" : volume
        self.volume = normalizedVolume
        self.installLocation = installLocation
        self.installTime = installTime
        self.packageFileName = packageFileName
        self.groups = groups
        self.isApplePackage = isApplePackage ?? packageIdentifier.lowercased().hasPrefix("com.apple.")
        self.isProtectedSystemPackage = isProtectedSystemPackage ?? SafetyGuard.isProtectedSystemPackage(packageID: packageIdentifier)
    }

    /// Root installation directory resolved from volume and installLocation.
    public var baseURL: URL {
        let volURL = URL(fileURLWithPath: volume)
        let trimmedLoc = installLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedLoc.isEmpty || trimmedLoc == "/" {
            return volURL.standardized
        }
        let cleanLoc = trimmedLoc.hasPrefix("/") ? String(trimmedLoc.dropFirst()) : trimmedLoc
        return volURL.appendingPathComponent(cleanLoc).standardized
    }

    /// Human-friendly package display name derived from the receipt filename or identifier.
    public var displayName: String {
        if let fileName = packageFileName?.trimmingCharacters(in: .whitespacesAndNewlines), !fileName.isEmpty {
            if fileName.lowercased().hasSuffix(".pkg") {
                return String(fileName.dropLast(4))
            }
            return fileName
        }

        var parts = packageIdentifier.split(separator: ".").map(String.init)
        if let last = parts.last?.lowercased(), last == "pkg" || last == "app" {
            parts.removeLast()
        }
        return parts.last ?? packageIdentifier
    }
}

public struct PackageContents: Equatable {
    public let files: [URL]
    public let directories: [URL]

    public init(files: [URL], directories: [URL]) {
        self.files = files
        self.directories = directories
    }
}

public struct SharedPackageFile: Codable, Equatable, Hashable {
    public let url: URL
    public let sharedWithPackages: [String]

    public init(url: URL, sharedWithPackages: [String]) {
        self.url = url
        self.sharedWithPackages = sharedWithPackages
    }
}

public struct PackageScanResult: Codable {
    public let packageInfo: PackageInfo
    public let items: [LeftoverItem]
    public let sharedFiles: [SharedPackageFile]
    public let missingFilePaths: [URL]
    public let protectedSkippedPaths: [URL]
    public let candidateEmptyDirectories: [URL]
    public let discoveredAppBundles: [AppInfo]
    public let totalSizeBytes: Int64
    public let packageFilesSizeBytes: Int64
    public let leftoversSizeBytes: Int64
    public let hasPrivilegedItems: Bool

    public init(
        packageInfo: PackageInfo,
        items: [LeftoverItem],
        sharedFiles: [SharedPackageFile] = [],
        missingFilePaths: [URL] = [],
        protectedSkippedPaths: [URL] = [],
        candidateEmptyDirectories: [URL] = [],
        discoveredAppBundles: [AppInfo] = []
    ) {
        self.packageInfo = packageInfo
        self.items = items
        self.sharedFiles = sharedFiles
        self.missingFilePaths = missingFilePaths
        self.protectedSkippedPaths = protectedSkippedPaths
        self.candidateEmptyDirectories = candidateEmptyDirectories
        self.discoveredAppBundles = discoveredAppBundles

        let pkgBytes = items
            .filter { $0.category.hasPrefix("Package ") }
            .reduce(0) { $0 + $1.sizeBytes }
        let total = items.reduce(0) { $0 + $1.sizeBytes }
        self.packageFilesSizeBytes = pkgBytes
        self.leftoversSizeBytes = max(0, total - pkgBytes)
        self.totalSizeBytes = total
        self.hasPrivilegedItems = items.contains { $0.requiresPrivilege }
    }

    public var groupedByCategory: [String: [LeftoverItem]] {
        Dictionary(grouping: items, by: { $0.category })
    }
}

public struct PackageRemovalPlan: Codable {
    public let packageInfo: PackageInfo
    public let selectedItems: [LeftoverItem]
    public let candidateEmptyDirectories: [URL]
    public let isPermanent: Bool
    public let dryRun: Bool
    public let keepReceipt: Bool
    public let totalSizeBytes: Int64

    public init(
        packageInfo: PackageInfo,
        selectedItems: [LeftoverItem],
        candidateEmptyDirectories: [URL] = [],
        isPermanent: Bool = false,
        dryRun: Bool = false,
        keepReceipt: Bool = false
    ) {
        self.packageInfo = packageInfo
        self.selectedItems = selectedItems
        self.candidateEmptyDirectories = candidateEmptyDirectories
        self.isPermanent = isPermanent
        self.dryRun = dryRun
        self.keepReceipt = keepReceipt
        self.totalSizeBytes = selectedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    public var hasPrivilegedItems: Bool {
        return selectedItems.contains { $0.requiresPrivilege }
    }

    public var totalItemsCount: Int {
        return selectedItems.count
    }
}

public struct PackageRemovalExecutionResult {
    public let successfulItems: [RemovalItemResult]
    public let failedItems: [RemovalItemResult]
    public let prunedDirectories: [URL]
    public let receiptForgotten: Bool
    public let receiptForgetError: String?
    public let record: RemovalRecord

    public var isCompleteSuccess: Bool {
        return failedItems.isEmpty && receiptForgetError == nil
    }
}
