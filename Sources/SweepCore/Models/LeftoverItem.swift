import Foundation

public enum Confidence: String, Codable, Comparable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"

    private var sortOrder: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
        return lhs.sortOrder < rhs.sortOrder
    }
}

public struct LeftoverItem: Codable, Equatable, Hashable {
    public let url: URL
    public let sizeBytes: Int64
    public let category: String
    public let confidence: Confidence
    public let matchReason: String
    public let requiresPrivilege: Bool

    public init(
        url: URL,
        sizeBytes: Int64,
        category: String,
        confidence: Confidence,
        matchReason: String,
        requiresPrivilege: Bool = false
    ) {
        self.url = url
        self.sizeBytes = sizeBytes
        self.category = category
        self.confidence = confidence
        self.matchReason = matchReason
        self.requiresPrivilege = requiresPrivilege
    }
}

public struct ScanResult: Codable {
    public let appInfo: AppInfo
    public let leftovers: [LeftoverItem]
    public let totalSizeBytes: Int64
    public let hasPrivilegedItems: Bool

    public init(appInfo: AppInfo, leftovers: [LeftoverItem]) {
        self.appInfo = appInfo
        self.leftovers = leftovers
        let leftoverSum = leftovers.reduce(0) { $0 + $1.sizeBytes }
        self.totalSizeBytes = appInfo.bundleSizeBytes + leftoverSum
        self.hasPrivilegedItems = leftovers.contains(where: { $0.requiresPrivilege })
    }

    /// Leftovers grouped by category/domain
    public var groupedByCategory: [String: [LeftoverItem]] {
        Dictionary(grouping: leftovers, by: { $0.category })
    }
}
