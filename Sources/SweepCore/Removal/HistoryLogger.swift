import Foundation

public struct RemovalItemRecord: Codable, Equatable {
    public let originalPath: String
    public let trashPath: String?
    public let category: String
    public let sizeBytes: Int64

    public init(originalPath: String, trashPath: String?, category: String, sizeBytes: Int64) {
        self.originalPath = originalPath
        self.trashPath = trashPath
        self.category = category
        self.sizeBytes = sizeBytes
    }
}

public struct RemovalRecord: Codable, Equatable {
    public let id: String
    public let timestamp: String
    public let bundleIdentifier: String
    public let appName: String
    public let appVersion: String?
    public let isPermanent: Bool
    public let totalSizeBytes: Int64
    public let items: [RemovalItemRecord]

    public init(
        id: String = UUID().uuidString,
        timestamp: String = ISO8601DateFormatter().string(from: Date()),
        bundleIdentifier: String,
        appName: String,
        appVersion: String?,
        isPermanent: Bool,
        totalSizeBytes: Int64,
        items: [RemovalItemRecord]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.appVersion = appVersion
        self.isPermanent = isPermanent
        self.totalSizeBytes = totalSizeBytes
        self.items = items
    }
}

public final class HistoryLogger {
    private let fileManager: FileManager
    private let manifestURL: URL

    public init(fileManager: FileManager = .default, customManifestURL: URL? = nil) {
        self.fileManager = fileManager
        if let custom = customManifestURL {
            self.manifestURL = custom
        } else {
            let configDir = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".config")
                .appendingPathComponent("sweep")
            self.manifestURL = configDir.appendingPathComponent("history.json")
        }
    }

    /// Loads all historic removal records
    public func loadHistory() -> [RemovalRecord] {
        guard fileManager.fileExists(atPath: manifestURL.path) else { return [] }
        guard let data = try? Data(contentsOf: manifestURL),
              let records = try? JSONDecoder().decode([RemovalRecord].self, from: data) else {
            return []
        }
        return records
    }

    /// Atomically appends a new removal transaction
    public func recordRemoval(_ record: RemovalRecord) throws {
        let parentDir = manifestURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        var history = loadHistory()
        history.append(record)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(history)

        try data.write(to: manifestURL, options: .atomic)
    }
}
