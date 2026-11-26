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
        "/usr/bin",
        "/usr/sbin",
        "/usr/lib",
        "/usr/libexec",
        "/usr/share",
        "/usr/include",
        "/usr/standalone",
        "/usr/X11",
        "/usr/X11R6",
        "/bin",
        "/sbin",
        "/private/etc",
        "/private/var/db",
        "/private/var/root",
        "/Library/Apple",
        "/Library/Application Support/Apple",
        "/Library/SystemExtensions",
        "/Library/Keychains",
        "/Library/Receipts",
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
        "Library/Safari",
        "Library/Application Support/Apple"
    ]

    /// Structural directory roots that can NEVER be deleted itself as a leftover or package root
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
        "Applications",
        "Extensions",
        "Frameworks",
        "Java",
        "JavaVirtualMachines",
        "Input Methods",
        "PreferencePanes",
        "Internet Plug-Ins",
        "Fonts",
        "Receipts",
        "Utilities"
    ]

    /// Structural directories under /usr/local, /opt/homebrew, and /opt that must NEVER be deleted as a whole
    public static let protectedPackageRootSubdirs: Set<String> = [
        "local",
        "bin",
        "sbin",
        "lib",
        "libexec",
        "share",
        "man",
        "doc",
        "info",
        "include",
        "etc",
        "var",
        "opt",
        "Cellar",
        "Caskroom",
        "Homebrew",
        "homebrew",
        "Frameworks"
    ]

    /// Apple essential core system apps that can NEVER be deleted
    public static let coreSystemAppBundles: Set<String> = [
        "com.apple.finder",
        "com.apple.safari",
        "com.apple.systempreferences",
        "com.apple.settings",
        "com.apple.terminal",
        "com.apple.appstore",
        "com.apple.launchd"
    ]

    /// Package identifier prefixes belonging to core macOS system/security/template receipts
    public static let protectedSystemPackagePrefixes: [String] = [
        "com.apple.files.",
        "com.apple.cdm.pkg.setupmacos",
        "com.apple.pkg.coretypes",
        "com.apple.pkg.xprotect",
        "com.apple.pkg.mrtconfigdata",
        "com.apple.pkg.gatekeepercompatibilitydata",
        "com.apple.pkg.mobileassets",
        "com.apple.pkg.mobiledevice",
        "com.apple.pkg.rosetta",
        "com.apple.pkg.macos",
        "com.apple.pkg.basesystem",
        "com.apple.pkg.essentials",
        "com.apple.pkg.safari",
        "com.apple.pkg.finder",
        "com.apple.pkg.firmware",
        "com.apple.pkg.bridgeos",
        "com.apple.pkg.xcodesystemresources"
    ]

    /// Checks if a package identifier refers to a core macOS system package that must not be uninstalled
    public static func isProtectedSystemPackage(packageID: String) -> Bool {
        let lower = packageID.lowercased()
        return protectedSystemPackagePrefixes.contains { lower.hasPrefix($0) }
    }

    /// Checks if an app is a sealed core macOS system application
    public static func isProtectedSystemApp(bundleIdentifier: String, bundleURL: URL) -> Bool {
        let bundleID = bundleIdentifier.lowercased()
        let path = bundleURL.resolvingSymlinksInPath().standardized.path

        // Sealed read-only APFS volume: /System, /System/Applications
        if path.hasPrefix("/System/") || path.hasPrefix("/System/Applications") || path.hasPrefix("/System/Volumes/Data/System/") {
            return true
        }

        // Essential core system application
        if coreSystemAppBundles.contains(bundleID) {
            return true
        }

        return false
    }

    /// Validates an item path against all safety rules. Throws `SweepError` if unsafe.
    public func validate(itemURL: URL, for appInfo: AppInfo? = nil, isCacheOnly: Bool = false) throws {
        let rawPath = itemURL.standardized.path

        // Check 1: Must be absolute and non-empty
        guard !rawPath.isEmpty, rawPath != "/" else {
            throw SweepError.protectedSystemComponent("Path is empty or root filesystem.")
        }

        // Check 2: Core macOS system bundle protection (the app bundle itself can never be deleted)
        if let appInfo = appInfo {
            if Self.isProtectedSystemApp(bundleIdentifier: appInfo.bundleIdentifier, bundleURL: appInfo.bundleURL) {
                let itemCanonical = itemURL.resolvingSymlinksInPath().standardized.path
                let appCanonical = appInfo.bundleURL.resolvingSymlinksInPath().standardized.path
                if itemCanonical == appCanonical || itemURL.standardized.path == appInfo.bundleURL.standardized.path {
                    throw SweepError.protectedSystemComponent("Target '\(appInfo.bundleName)' (\(appInfo.bundleIdentifier)) is a sealed macOS system-protected application.")
                }
            }
        }

        // Check 3: Cannot delete protected structural root directories
        let lastComponent = itemURL.lastPathComponent
        let parentURL = itemURL.deletingLastPathComponent()
        let parent = parentURL.lastPathComponent
        let grandParent = parentURL.deletingLastPathComponent().lastPathComponent

        if Self.protectedRootFolderNames.contains(lastComponent) {
            if lastComponent == "Library" ||
               lastComponent == "Applications" ||
               parent == "Library" ||
               (grandParent == "Library" && lastComponent == "JavaVirtualMachines") ||
               (parent == "Applications" && lastComponent == "Utilities") ||
               parent == "Users" ||
               parent == "/" ||
               grandParent == "Users" ||
               parent.hasSuffix("Home") {
                throw SweepError.protectedSystemComponent("Cannot delete system structural root folder: '\(rawPath)'.")
            }
        }

        if Self.protectedPackageRootSubdirs.contains(lastComponent) {
            if (parent == "local" && grandParent == "usr") ||
               (parent == "homebrew" && grandParent == "opt") ||
               (parent == "local" && grandParent == "opt") ||
               (parent == "share" && (grandParent == "local" || grandParent == "homebrew")) ||
               parent == "opt" ||
               (parent == "/" && (lastComponent == "opt" || lastComponent == "usr")) {
                throw SweepError.protectedSystemComponent("Cannot delete package structural root folder: '\(rawPath)'.")
            }
        }
        if parent == "man" && grandParent == "share" && lastComponent.hasPrefix("man") {
            throw SweepError.protectedSystemComponent("Cannot delete manual section directory: '\(rawPath)'.")
        }
        if (parent == "Caches" && lastComponent == "Homebrew") ||
           (parent == "Homebrew" && ["downloads", "Cask", "api", "bootsnap"].contains(lastComponent)) {
            throw SweepError.protectedSystemComponent("Cannot delete Homebrew cache root directory: '\(rawPath)'.")
        }
        let homeStdPath = fileManager.homeDirectoryForCurrentUser.standardized.path
        if lastComponent == ".config" && (parentURL.standardized.path == homeStdPath || parent == "Users" || grandParent == "Users" || parent.hasSuffix("Home")) {
            throw SweepError.protectedSystemComponent("Cannot delete user config root directory: '\(rawPath)'.")
        }

        // Check 4: Symlink traversal & canonical path resolution
        let canonicalURL = itemURL.resolvingSymlinksInPath().standardized
        let canonicalPath = canonicalURL.path

        if canonicalPath == "/usr" ||
           canonicalPath == "/usr/local" ||
           canonicalPath == "/opt" ||
           (canonicalPath.hasPrefix("/usr/") && !canonicalPath.hasPrefix("/usr/local/")) {
            throw SweepError.protectedSystemComponent("Path is protected by macOS System Integrity: '\(rawPath)'.")
        }

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
        if canonicalPath == homePath {
            throw SweepError.protectedSystemComponent("Cannot delete user home directory: '\(rawPath)'.")
        }

        var isInsideHome = canonicalPath.hasPrefix(homePath + "/")
        if !isInsideHome && canonicalPath.hasPrefix("/Users/") {
            let parts = canonicalPath.split(separator: "/")
            if parts.count >= 2 && parts[0] == "Users" {
                isInsideHome = true
            }
        }
        let isInsideApplications = canonicalPath.hasPrefix("/Applications/") || canonicalPath.hasPrefix("/System/Volumes/Data/Applications/")
        let isInsideLibrary = canonicalPath.hasPrefix("/Library/") || canonicalPath.hasPrefix("/System/Volumes/Data/Library/")
        let isInsideDarwin = canonicalPath.hasPrefix("/private/var/folders/") || canonicalPath.hasPrefix("/var/folders/")
        let isInsideUsrLocal = !isCacheOnly && canonicalPath.hasPrefix("/usr/local/")
        let isInsideOpt = !isCacheOnly && canonicalPath.hasPrefix("/opt/")

        guard isInsideHome || isInsideApplications || isInsideLibrary || isInsideDarwin || isInsideUsrLocal || isInsideOpt else {
            throw SweepError.protectedSystemComponent("Path '\(rawPath)' is outside allowed macOS application, package, and user domains.")
        }
    }
}
