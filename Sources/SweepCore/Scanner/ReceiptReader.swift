import Foundation

public protocol ReceiptReading {
    func findPackages(matching bundleID: String, appName: String) -> [String]
    func filesForPackage(_ pkgID: String) -> [URL]
}

public final class ReceiptReader: ReceiptReading {
    public static let shared = ReceiptReader()

    public init() {}

    private var cachedPackages: [String]?

    /// Runs `pkgutil --pkgs` and finds receipts matching the bundle identifier or app name
    public func findPackages(matching bundleID: String, appName: String) -> [String] {
        let allPackages: [String]
        if let cached = cachedPackages {
            allPackages = cached
        } else {
            let output = runCommand("/usr/sbin/pkgutil", ["--pkgs"])
            guard !output.isEmpty else { return [] }
            allPackages = output
                .split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            self.cachedPackages = allPackages
        }

        let normalizedApp = appName.lowercased()
        let normalizedBundle = bundleID.lowercased()

        return allPackages.filter { line in
            let lower = line.lowercased()
            return lower == normalizedBundle ||
                   lower.contains(normalizedBundle) ||
                   (!normalizedApp.isEmpty && normalizedApp.count > 3 && lower.contains(normalizedApp))
        }
    }

    /// Queries `pkgutil --pkg-info` and `pkgutil --files` to resolve absolute file URLs
    public func filesForPackage(_ pkgID: String) -> [URL] {
        let infoOutput = runCommand("/usr/sbin/pkgutil", ["--pkg-info", pkgID])
        var volume = "/"
        var location = ""

        for line in infoOutput.split(separator: "\n") {
            let str = String(line)
            if str.hasPrefix("volume: ") {
                volume = String(str.dropFirst("volume: ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if str.hasPrefix("location: ") {
                location = String(str.dropFirst("location: ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let filesOutput = runCommand("/usr/sbin/pkgutil", ["--files", pkgID])
        guard !filesOutput.isEmpty else { return [] }

        let basePath = (volume as NSString).appendingPathComponent(location)
        var urls: [URL] = []
        let fileManager = FileManager.default

        for line in filesOutput.split(separator: "\n") {
            let relativePath = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !relativePath.isEmpty else { continue }
            let fullPath = (basePath as NSString).appendingPathComponent(relativePath)
            if fileManager.fileExists(atPath: fullPath) {
                urls.append(URL(fileURLWithPath: fullPath))
            }
        }

        return urls
    }

    private func runCommand(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
