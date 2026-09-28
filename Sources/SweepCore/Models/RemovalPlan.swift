import Foundation

public struct RemovalPlan: Codable {
    public let appInfo: AppInfo
    public let selectedItems: [LeftoverItem]
    public let isPermanent: Bool
    public let dryRun: Bool
    public let totalSizeBytes: Int64

    public init(
        appInfo: AppInfo,
        selectedItems: [LeftoverItem],
        isPermanent: Bool = false,
        dryRun: Bool = false
    ) {
        self.appInfo = appInfo
        self.selectedItems = selectedItems
        self.isPermanent = isPermanent
        self.dryRun = dryRun
        let leftoversSum = selectedItems.reduce(0) { $0 + $1.sizeBytes }
        self.totalSizeBytes = appInfo.bundleSizeBytes + leftoversSum
    }

    public var hasPrivilegedItems: Bool {
        return selectedItems.contains(where: { $0.requiresPrivilege })
    }

    public var totalItemsCount: Int {
        return 1 + selectedItems.count // 1 for .app bundle itself + leftovers
    }
}
