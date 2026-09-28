import Foundation
@testable import SweepCore

public final class DummyAppBuilder {
    public static func createDummyApp(
        in directory: URL,
        bundleName: String,
        bundleIdentifier: String,
        executableName: String = "AppBinary",
        version: String = "1.0.0"
    ) throws -> URL {
        let fileManager = FileManager.default
        let appBundleURL = directory.appendingPathComponent("\(bundleName).app")
        let contentsURL = appBundleURL.appendingPathComponent("Contents")
        let macosURL = contentsURL.appendingPathComponent("MacOS")

        try fileManager.createDirectory(at: macosURL, withIntermediateDirectories: true)

        // Create dummy executable
        let execURL = macosURL.appendingPathComponent(executableName)
        try "dummy-binary".write(to: execURL, atomically: true, encoding: .utf8)

        // Create Info.plist
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": bundleName,
            "CFBundleDisplayName": bundleName,
            "CFBundleExecutable": executableName,
            "CFBundleShortVersionString": version
        ]

        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let infoPlistURL = contentsURL.appendingPathComponent("Info.plist")
        try plistData.write(to: infoPlistURL)

        return appBundleURL
    }

    public static func populateLeftovers(
        sandbox: TestSandbox,
        bundleIdentifier: String,
        bundleName: String,
        vendorToken: String?
    ) throws {
        let fm = FileManager.default
        let lib = sandbox.userLibraryURL

        // High confidence: container directory & preference plist
        let container = lib.appendingPathComponent("Containers").appendingPathComponent(bundleIdentifier)
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        try "container-content".write(to: container.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)

        let pref = lib.appendingPathComponent("Preferences").appendingPathComponent("\(bundleIdentifier).plist")
        try "pref-content".write(to: pref, atomically: true, encoding: .utf8)

        // Medium confidence: App Support folder & Cache folder with bundleName
        let appSupport = lib.appendingPathComponent("Application Support").appendingPathComponent(bundleName)
        try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try "app-support-data".write(to: appSupport.appendingPathComponent("db.sqlite"), atomically: true, encoding: .utf8)

        let cache = lib.appendingPathComponent("Caches").appendingPathComponent(bundleName)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try "cache-data".write(to: cache.appendingPathComponent("cache.bin"), atomically: true, encoding: .utf8)

        // Low confidence: vendor folder
        if let vendor = vendorToken {
            let vendorFolder = lib.appendingPathComponent("Application Support").appendingPathComponent(vendor)
            try fm.createDirectory(at: vendorFolder, withIntermediateDirectories: true)
            try "vendor-data".write(to: vendorFolder.appendingPathComponent("vendor.txt"), atomically: true, encoding: .utf8)
        }

        // Noise (files from other unrelated apps that must NOT match)
        let noiseAppSupport = lib.appendingPathComponent("Application Support").appendingPathComponent("UnrelatedSoftware")
        try fm.createDirectory(at: noiseAppSupport, withIntermediateDirectories: true)
        try "noise".write(to: noiseAppSupport.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let noisePref = lib.appendingPathComponent("Preferences").appendingPathComponent("com.unrelated.tool.plist")
        try "noise".write(to: noisePref, atomically: true, encoding: .utf8)
    }
}
