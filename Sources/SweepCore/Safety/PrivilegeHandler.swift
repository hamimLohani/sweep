import Foundation

public final class PrivilegeHandler {
    public static let shared = PrivilegeHandler()

    public init() {}

    /// Checks if current user is root
    public var isRoot: Bool {
        return geteuid() == 0
    }

    /// Checks if the current process has write permissions for the specified URL
    public func canWrite(to url: URL) -> Bool {
        return access(url.path, W_OK) == 0
    }

    /// Prompts for administrator credentials interactively using sudo -v if needed
    public func authenticateIfNeeded() throws {
        if isRoot { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-v"]
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SweepError.permissionDenied("Administrator authentication failed.")
        }
    }

    /// Removes a privileged file/directory using /usr/bin/sudo rm -rf with interactive terminal support
    public func removeWithPrivilege(at url: URL) throws {
        if isRoot {
            try FileManager.default.removeItem(at: url)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["/bin/rm", "-rf", url.path]
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw SweepError.permissionDenied("sudo rm failed for '\(url.path)' with exit code \(process.terminationStatus)")
        }
    }
}

