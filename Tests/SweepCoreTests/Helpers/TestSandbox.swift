import Foundation

public final class TestSandbox {
    public let rootURL: URL
    public let applicationsURL: URL
    public let userHomeURL: URL
    public let userLibraryURL: URL
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sweep_test_\(UUID().uuidString)")
        self.rootURL = tempDir
        self.applicationsURL = tempDir.appendingPathComponent("Applications")
        self.userHomeURL = tempDir.appendingPathComponent("UserHome")
        self.userLibraryURL = userHomeURL.appendingPathComponent("Library")

        try fileManager.createDirectory(at: applicationsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: userLibraryURL.appendingPathComponent("Application Support"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: userLibraryURL.appendingPathComponent("Caches"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: userLibraryURL.appendingPathComponent("Preferences"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: userLibraryURL.appendingPathComponent("Containers"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: userLibraryURL.appendingPathComponent("Saved Application State"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: userLibraryURL.appendingPathComponent("LaunchAgents"), withIntermediateDirectories: true)
    }

    public func cleanUp() {
        try? fileManager.removeItem(at: rootURL)
    }
}
