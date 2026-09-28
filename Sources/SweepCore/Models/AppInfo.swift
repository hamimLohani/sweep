import Foundation

public struct AppInfo: Codable, Equatable, Hashable {
    public let bundleURL: URL
    public let bundleIdentifier: String
    public let bundleName: String
    public let displayName: String
    public let executableName: String?
    public let vendorToken: String?
    public let version: String?
    public let bundleSizeBytes: Int64
    public let isSystemApp: Bool
    public let receiptPackages: [String]
    public let receiptFiles: [URL]

    public init(
        bundleURL: URL,
        bundleIdentifier: String,
        bundleName: String,
        displayName: String,
        executableName: String?,
        vendorToken: String?,
        version: String?,
        bundleSizeBytes: Int64,
        isSystemApp: Bool,
        receiptPackages: [String] = [],
        receiptFiles: [URL] = []
    ) {
        self.bundleURL = bundleURL
        self.bundleIdentifier = bundleIdentifier
        self.bundleName = bundleName
        self.displayName = displayName
        self.executableName = executableName
        self.vendorToken = vendorToken
        self.version = version
        self.bundleSizeBytes = bundleSizeBytes
        self.isSystemApp = isSystemApp
        self.receiptPackages = receiptPackages
        self.receiptFiles = receiptFiles
    }
}
