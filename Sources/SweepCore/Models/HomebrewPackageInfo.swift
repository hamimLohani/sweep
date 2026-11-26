import Foundation

public enum HomebrewPackageKind: String, Codable, Equatable, Hashable {
    case formula = "formula"
    case cask = "cask"

    public var displayLabel: String {
        switch self {
        case .formula: return "Formula"
        case .cask: return "Cask"
        }
    }
}

public struct HomebrewPackageInfo: Codable, Equatable, Hashable {
    public let name: String
    public let fullName: String
    public let kind: HomebrewPackageKind
    public let tap: String
    public let version: String
    public let installedTime: Date?
    public let descriptionText: String?
    public let homepage: String?
    public let prefixPath: String
    public let cellarOrCaskroomURL: URL?
    public let installedOnRequest: Bool
    public let isPinned: Bool
    public let isOutdated: Bool
    public let isKegOnly: Bool
    public let aliases: [String]
    public let oldNames: [String]
    public let displayNames: [String]
    public let dependencies: [String]
    public let runtimeDependencies: [String]
    public let requiredBy: [String]
    public let serviceName: String?
    public let serviceRunning: Bool
    public let servicePlistPath: String?
    public let artifactAppPaths: [String]
    public let artifactBinaryPaths: [String]
    public let artifactFontPaths: [String]
    public let artifactManpagePaths: [String]
    public let artifactPkgIDs: [String]
    public let zapTrashPaths: [String]
    public let zapDeletePaths: [String]
    public let zapRmdirPaths: [String]

    public init(
        name: String,
        fullName: String? = nil,
        kind: HomebrewPackageKind,
        tap: String = "homebrew/core",
        version: String,
        installedTime: Date? = nil,
        descriptionText: String? = nil,
        homepage: String? = nil,
        prefixPath: String = "/opt/homebrew",
        cellarOrCaskroomURL: URL? = nil,
        installedOnRequest: Bool = true,
        isPinned: Bool = false,
        isOutdated: Bool = false,
        isKegOnly: Bool = false,
        aliases: [String] = [],
        oldNames: [String] = [],
        displayNames: [String] = [],
        dependencies: [String] = [],
        runtimeDependencies: [String] = [],
        requiredBy: [String] = [],
        serviceName: String? = nil,
        serviceRunning: Bool = false,
        servicePlistPath: String? = nil,
        artifactAppPaths: [String] = [],
        artifactBinaryPaths: [String] = [],
        artifactFontPaths: [String] = [],
        artifactManpagePaths: [String] = [],
        artifactPkgIDs: [String] = [],
        zapTrashPaths: [String] = [],
        zapDeletePaths: [String] = [],
        zapRmdirPaths: [String] = []
    ) {
        self.name = name
        self.fullName = fullName ?? name
        self.kind = kind
        self.tap = tap
        self.version = version
        self.installedTime = installedTime
        self.descriptionText = descriptionText
        self.homepage = homepage
        self.prefixPath = prefixPath
        self.cellarOrCaskroomURL = cellarOrCaskroomURL
        self.installedOnRequest = installedOnRequest
        self.isPinned = isPinned
        self.isOutdated = isOutdated
        self.isKegOnly = isKegOnly
        self.aliases = aliases
        self.oldNames = oldNames
        self.displayNames = displayNames
        self.dependencies = dependencies
        self.runtimeDependencies = runtimeDependencies
        self.requiredBy = requiredBy
        self.serviceName = serviceName
        self.serviceRunning = serviceRunning
        self.servicePlistPath = servicePlistPath
        self.artifactAppPaths = artifactAppPaths
        self.artifactBinaryPaths = artifactBinaryPaths
        self.artifactFontPaths = artifactFontPaths
        self.artifactManpagePaths = artifactManpagePaths
        self.artifactPkgIDs = artifactPkgIDs
        self.zapTrashPaths = zapTrashPaths
        self.zapDeletePaths = zapDeletePaths
        self.zapRmdirPaths = zapRmdirPaths
    }

    public var primaryDisplayName: String {
        return displayNames.first ?? name
    }
}

public struct HomebrewScanResult: Codable {
    public let packageInfo: HomebrewPackageInfo
    public let cellarSizeBytes: Int64
    public let artifactItems: [LeftoverItem]
    public let cleanupItems: [LeftoverItem]
    public let discoveredAppBundles: [AppInfo]
    public let orphanedDependencies: [String]
    public let totalSizeBytes: Int64
    public let cleanupSizeBytes: Int64
    public let hasPrivilegedItems: Bool

    public init(
        packageInfo: HomebrewPackageInfo,
        cellarSizeBytes: Int64,
        artifactItems: [LeftoverItem],
        cleanupItems: [LeftoverItem],
        discoveredAppBundles: [AppInfo] = [],
        orphanedDependencies: [String] = []
    ) {
        self.packageInfo = packageInfo
        self.cellarSizeBytes = cellarSizeBytes
        self.artifactItems = artifactItems
        self.cleanupItems = cleanupItems
        self.discoveredAppBundles = discoveredAppBundles
        self.orphanedDependencies = orphanedDependencies

        let artifactsSum = artifactItems.reduce(0) { $0 + $1.sizeBytes }
        let cleanupSum = cleanupItems.reduce(0) { $0 + $1.sizeBytes }
        self.cleanupSizeBytes = cleanupSum
        self.totalSizeBytes = cellarSizeBytes + artifactsSum + cleanupSum
        self.hasPrivilegedItems = cleanupItems.contains { $0.requiresPrivilege } || artifactItems.contains { $0.requiresPrivilege }
    }

    public var groupedCleanupByCategory: [String: [LeftoverItem]] {
        Dictionary(grouping: cleanupItems, by: { $0.category })
    }
}

public struct HomebrewRemovalPlan: Codable {
    public let packageInfo: HomebrewPackageInfo
    public let selectedCleanupItems: [LeftoverItem]
    public let isPermanent: Bool
    public let dryRun: Bool
    public let ignoreDependencies: Bool
    public let force: Bool
    public let autoremove: Bool
    public let cellarSizeBytes: Int64
    public let totalSizeBytes: Int64

    public init(
        packageInfo: HomebrewPackageInfo,
        selectedCleanupItems: [LeftoverItem],
        isPermanent: Bool = false,
        dryRun: Bool = false,
        ignoreDependencies: Bool = false,
        force: Bool = false,
        autoremove: Bool = false,
        cellarSizeBytes: Int64 = 0,
        artifactSizeBytes: Int64 = 0
    ) {
        self.packageInfo = packageInfo
        self.selectedCleanupItems = selectedCleanupItems
        self.isPermanent = isPermanent
        self.dryRun = dryRun
        self.ignoreDependencies = ignoreDependencies
        self.force = force
        self.autoremove = autoremove
        self.cellarSizeBytes = cellarSizeBytes
        let cleanupSum = selectedCleanupItems.reduce(0) { $0 + $1.sizeBytes }
        self.totalSizeBytes = cellarSizeBytes + artifactSizeBytes + cleanupSum
    }

    public var hasPrivilegedItems: Bool {
        return selectedCleanupItems.contains { $0.requiresPrivilege }
    }
}

public struct HomebrewRemovalExecutionResult {
    public let serviceStopped: Bool
    public let brewUninstalled: Bool
    public let brewOutput: String
    public let autoremoveExecuted: Bool
    public let autoremoveOutput: String?
    public let successfulCleanupItems: [RemovalItemResult]
    public let failedCleanupItems: [RemovalItemResult]
    public let record: RemovalRecord

    public var isCompleteSuccess: Bool {
        return brewUninstalled && failedCleanupItems.isEmpty
    }
}
