import AppKit
import Foundation

public final class ProcessManager {
    public static let shared = ProcessManager()

    public init() {}

    /// Checks if any instances of the application are running
    public func isAppRunning(bundleIdentifier: String) -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        return !running.isEmpty
    }

    /// Attempts to gracefully terminate the application, with force-terminate fallback
    public func quitApp(bundleIdentifier: String, force: Bool = false) -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        guard !running.isEmpty else { return true }

        for app in running {
            if force {
                app.forceTerminate()
            } else {
                app.terminate()
            }
        }

        // Wait up to 3 seconds for process to exit
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            let stillRunning = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            if stillRunning.isEmpty {
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        // If not forced and still running, attempt force terminate
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
            app.forceTerminate()
        }

        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    /// Unloads a LaunchAgent or LaunchDaemon using modern `launchctl bootout`
    public func unloadLaunchAgentOrDaemon(at plistURL: URL, isDaemon: Bool) -> (success: Bool, message: String) {
        let uid = getuid()
        let targetDomain = isDaemon ? "system" : "gui/\(uid)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", targetDomain, plistURL.path]

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return (true, "Unloaded \(plistURL.lastPathComponent)")
            } else {
                let errData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8) ?? ""
                return (false, "launchctl bootout: \(errMsg.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
