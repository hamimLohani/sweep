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

    /// Removes a privileged file/directory using /usr/bin/sudo rm -rf with explicit transparent execution
    public func removeWithPrivilege(at url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["/bin/rm", "-rf", url.path]

        let errPipe = Pipe()
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "Failed with exit code \(process.terminationStatus)"
            throw SweepError.permissionDenied("sudo rm failed for '\(url.path)': \(errMsg.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
