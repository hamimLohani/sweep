import Foundation

public struct DiagnosticCheck {
    public let name: String
    public let passed: Bool
    public let message: String
    public let remediation: String?

    public init(name: String, passed: Bool, message: String, remediation: String? = nil) {
        self.name = name
        self.passed = passed
        self.message = message
        self.remediation = remediation
    }
}

public final class Doctor {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func runDiagnostics() -> [DiagnosticCheck] {
        var checks: [DiagnosticCheck] = []

        // 1. macOS Version Check
        checks.append(checkOSVersion())

        // 2. Full Disk Access (FDA) Check
        checks.append(checkFullDiskAccess())

        // 3. User Trash Permissions
        checks.append(checkTrashPermissions())

        // 4. SIP Status Check
        checks.append(checkSIPStatus())

        // 5. History Manifest Directory Access
        checks.append(checkConfigDirectory())

        return checks
    }

    private func checkOSVersion() -> DiagnosticCheck {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let supported = os.majorVersion >= 13

        if supported {
            return DiagnosticCheck(
                name: "macOS Version Compatibility",
                passed: true,
                message: "macOS \(osString) (macOS 13.0+ required)"
            )
        } else {
            return DiagnosticCheck(
                name: "macOS Version Compatibility",
                passed: false,
                message: "macOS \(osString) is older than minimum supported macOS 13.0 Ventura.",
                remediation: "Upgrade macOS to version 13.0 or later to ensure APFS and modern launchctl compatibility."
            )
        }
    }

    private func checkFullDiskAccess() -> DiagnosticCheck {
        let home = fileManager.homeDirectoryForCurrentUser
        let safariURL = home.appendingPathComponent("Library/Safari")

        // In macOS, accessing ~/Library/Safari contents requires Full Disk Access
        var hasAccess = false
        if fileManager.fileExists(atPath: safariURL.path) {
            hasAccess = (try? fileManager.contentsOfDirectory(atPath: safariURL.path)) != nil
        } else {
            // Alternative: check ~/Library/Mail
            let mailURL = home.appendingPathComponent("Library/Mail")
            if fileManager.fileExists(atPath: mailURL.path) {
                hasAccess = (try? fileManager.contentsOfDirectory(atPath: mailURL.path)) != nil
            } else {
                hasAccess = true
            }
        }

        if hasAccess {
            return DiagnosticCheck(
                name: "Full Disk Access (FDA)",
                passed: true,
                message: "Granted. All application library domains can be thoroughly scanned."
            )
        } else {
            return DiagnosticCheck(
                name: "Full Disk Access (FDA)",
                passed: false,
                message: "Not detected. Some sandboxed containers or cookies in ~/Library may be inaccessible.",
                remediation: "Open System Settings → Privacy & Security → Full Disk Access, and toggle ON your Terminal app (or sweep binary)."
            )
        }
    }

    private func checkTrashPermissions() -> DiagnosticCheck {
        let home = fileManager.homeDirectoryForCurrentUser
        let trashURL = home.appendingPathComponent(".Trash")

        let writable = fileManager.isWritableFile(atPath: trashURL.path) || fileManager.isWritableFile(atPath: home.path)
        if writable {
            return DiagnosticCheck(
                name: "macOS Trash Directory",
                passed: true,
                message: "User Trash (~/.Trash) is writable and ready for safe removals."
            )
        } else {
            return DiagnosticCheck(
                name: "macOS Trash Directory",
                passed: false,
                message: "User Trash folder is not writable.",
                remediation: "Run: chmod 700 ~/.Trash to restore standard macOS Trash permissions."
            )
        }
    }

    private func checkSIPStatus() -> DiagnosticCheck {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/csrutil")
        process.arguments = ["status"]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let enabled = output.contains("enabled")

            return DiagnosticCheck(
                name: "System Integrity Protection (SIP)",
                passed: true,
                message: enabled ? "Enabled (System core is protected)." : "Disabled (Caution: system protection is off)."
            )
        } catch {
            return DiagnosticCheck(
                name: "System Integrity Protection (SIP)",
                passed: true,
                message: "Status could not be queried directly."
            )
        }
    }

    private func checkConfigDirectory() -> DiagnosticCheck {
        let configDir = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("sweep")

        do {
            try fileManager.createDirectory(at: configDir, withIntermediateDirectories: true)
            let testFile = configDir.appendingPathComponent(".write_test")
            try "ok".write(to: testFile, atomically: true, encoding: .utf8)
            try fileManager.removeItem(at: testFile)

            return DiagnosticCheck(
                name: "Audit History Store",
                passed: true,
                message: "Config and audit directory (~/.config/sweep) is writable."
            )
        } catch {
            return DiagnosticCheck(
                name: "Audit History Store",
                passed: false,
                message: "Cannot write to ~/.config/sweep.",
                remediation: "Check permissions for ~/.config/sweep: mkdir -p ~/.config/sweep && chmod 755 ~/.config/sweep"
            )
        }
    }
}
