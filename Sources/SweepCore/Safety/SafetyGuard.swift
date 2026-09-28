import Foundation

public final class SafetyGuard {
    private let fileManager: FileManager
    private let customAllowedRoot: URL?

    public init(fileManager: FileManager = .default, customAllowedRoot: URL? = nil) {
        self.fileManager = fileManager
        self.customAllowedRoot = customAllowedRoot
    }

    /// Hardcoded system directories that must NEVER be touched under any circumstances
    public static let strictDenylist: [String] = [
        "/",
        "/System",
        "/usr",
        "/bin",
        "/sbin",
        "/private/etc",
        "/private/var/db",
        "/private/var/root",
        "/Library/Apple",
        "/Library/SystemExtensions",
        "/Library/Keychains",
        "/System/Library",
        "/System/Volumes"
    ]

    /// Sensitive user-data directories that must NEVER be deleted by an uninstaller
    public static let sensitiveUserDenylist: [String] = [
        "Library/Keychains",
        "Library/AuthenticationServices",
        "Library/IdentityServices",
        "Library/Accounts",
        "Library/Mail",
        "Library/Messages",
        "Library/Safari"
    ]

    /// Structural directory roots that can NEVER be deleted itself as a leftover
    public static let protectedRootFolderNames: Set<String> = [
        "Library",
        "Application Support",
        "Caches",
        "Preferences",
        "Containers",
        "Group Containers",
        "Saved Application State",
        "Logs",
        "HTTPStorages",
        "WebKit",
        "Cookies",
        "LaunchAgents",
        "LaunchDaemons",
        "PrivilegedHelperTools",
        "Application Scripts",
        "Applications"
    ]

    /// Validates an item path against all safety rules. Throws `SweepError` if unsafe.
    public func validate(itemURL: URL, for appInfo: AppInfo? = nil) throws {
        let rawPath = itemURL.standardized.path

        // Check 1: Must be absolute and non-empty
        guard !rawPath.isEmpty, rawPath != "/" else {
            throw SweepError.protectedSystemComponent("Path is empty or root filesystem.")
        }

        // Check 2: Apple system bundle protection
        if let appInfo = appInfo {
            if appInfo.bundleIdentifier.lowercased().hasPrefix("com.apple.") || appInfo.isSystemApp {
                throw SweepError.protectedSystemComponent("Target '\(appInfo.bundleName)' is an Apple protected system application.")
            }
        }

        // Check 3: Cannot delete protected structural root directories
        let lastComponent = itemURL.lastPathComponent
        if Self.protectedRootFolderNames.contains(lastComponent) {
            // Check if the item IS the root folder itself rather than a sub-item
            let parent = itemURL.deletingLastPathComponent().lastPathComponent
            if parent == "Library" || parent == "Users" || parent == "/" {
                throw SweepError.protectedSystemComponent("Cannot delete system structural root folder: '\(rawPath)'.")
            }
        }

        // Check 4: Symlink traversal & canonical path resolution
        let canonicalURL = itemURL.resolvingSymlinksInPath().standardized
        let canonicalPath = canonicalURL.path

        // Check 5: Strict system denylist
        for denied in Self.strictDenylist {
            if canonicalPath == denied || canonicalPath.hasPrefix(denied + "/") {
                throw SweepError.protectedSystemComponent("Path is protected by macOS System Integrity: '\(rawPath)'.")
            }
        }

        // Check 6: User credential & sensitive directories denylist
        for sensitive in Self.sensitiveUserDenylist {
            if canonicalPath.contains("/" + sensitive + "/") || canonicalPath.hasSuffix("/" + sensitive) {
                throw SweepError.protectedSystemComponent("Path is a protected credential or sensitive personal directory: '\(rawPath)'.")
            }
        }

        // Check 7: Allowed parent roots confinement
        if let customRoot = customAllowedRoot {
            let rootPath = customRoot.standardized.path
            guard canonicalPath.hasPrefix(rootPath) else {
                throw SweepError.protectedSystemComponent("Path '\(rawPath)' escapes test sandbox '\(rootPath)'.")
            }
            return
        }

        let homePath = fileManager.homeDirectoryForCurrentUser.standardized.path
        let isInsideHome = canonicalPath.hasPrefix(homePath + "/")
        let isInsideApplications = canonicalPath.hasPrefix("/Applications/") || canonicalPath.hasPrefix("/System/Volumes/Data/Applications/")
        let isInsideLibrary = canonicalPath.hasPrefix("/Library/") || canonicalPath.hasPrefix("/System/Volumes/Data/Library/")
        let isInsideDarwin = canonicalPath.hasPrefix("/private/var/folders/") || canonicalPath.hasPrefix("/var/folders/")

        guard isInsideHome || isInsideApplications || isInsideLibrary || isInsideDarwin else {
            throw SweepError.protectedSystemComponent("Path '\(rawPath)' is outside allowed macOS application and user domains.")
        }
    }
}
