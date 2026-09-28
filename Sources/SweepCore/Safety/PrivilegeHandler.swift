import Foundation
import Darwin

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

    /// Checks if sudo credentials are currently active and cached
    public func hasCachedSudo() -> Bool {
        if isRoot { return true }
        var pid: pid_t = 0
        let cArgs: [UnsafeMutablePointer<CChar>?] = [
            strdup("/usr/bin/sudo"),
            strdup("-n"),
            strdup("-v"),
            nil
        ]
        defer {
            for ptr in cArgs {
                if let ptr = ptr { free(ptr) }
            }
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        guard posix_spawnp(&pid, "/usr/bin/sudo", &actions, nil, cArgs, environ) == 0 else {
            return false
        }
        var exitStatus: Int32 = 0
        waitpid(pid, &exitStatus, 0)
        return (exitStatus & 0x7F) == 0 && ((exitStatus >> 8) & 0xFF) == 0
    }

    /// Prompts for administrator credentials interactively using sudo -v if needed
    public func authenticateIfNeeded() throws {
        if isRoot { return }
        if hasCachedSudo() { return }

        // Spawn /usr/bin/sudo -v in the foreground process group so it attaches directly to the terminal TTY
        let exitCode = executeInForeground(command: "/usr/bin/sudo", arguments: ["-v"])
        guard exitCode == 0 else {
            throw SweepError.permissionDenied("Administrator authentication failed or was cancelled.")
        }
    }

    /// Removes a privileged file/directory using /usr/bin/sudo rm -rf with interactive terminal support
    public func removeWithPrivilege(at url: URL) throws {
        if isRoot {
            try FileManager.default.removeItem(at: url)
            return
        }

        let exitCode = executeInForeground(command: "/usr/bin/sudo", arguments: ["/bin/rm", "-rf", url.path])
        if exitCode != 0 {
            throw SweepError.permissionDenied("sudo rm failed for '\(url.path)' with exit code \(exitCode)")
        }
    }

    /// Executes a process using posix_spawnp in the foreground terminal process group
    @discardableResult
    private func executeInForeground(command: String, arguments: [String]) -> Int32 {
        var pid: pid_t = 0
        let allArgs = [command] + arguments
        let cArgs: [UnsafeMutablePointer<CChar>?] = allArgs.map { strdup($0) } + [nil]
        defer {
            for ptr in cArgs {
                if let ptr = ptr { free(ptr) }
            }
        }

        let spawnStatus = posix_spawnp(&pid, command, nil, nil, cArgs, environ)
        guard spawnStatus == 0 else {
            return -1
        }

        var exitStatus: Int32 = 0
        waitpid(pid, &exitStatus, 0)

        if (exitStatus & 0x7F) == 0 {
            return (exitStatus >> 8) & 0xFF
        } else {
            return 128 + (exitStatus & 0x7F)
        }
    }
}

