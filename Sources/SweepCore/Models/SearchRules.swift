import Foundation

public struct SearchRule: Codable, Equatable {
    public let id: String
    public let name: String
    public let domain: String
    public let pathTemplate: String
    public let matchStrategy: String
    public let requiresPrivilege: Bool

    public init(
        id: String,
        name: String,
        domain: String,
        pathTemplate: String,
        matchStrategy: String,
        requiresPrivilege: Bool
    ) {
        self.id = id
        self.name = name
        self.domain = domain
        self.pathTemplate = pathTemplate
        self.matchStrategy = matchStrategy
        self.requiresPrivilege = requiresPrivilege
    }
}

public struct SearchRuleLoader {
    /// Loads search rules from the bundled resource, fallback string, or specified URL
    public static func loadRules(from customURL: URL? = nil) -> [SearchRule] {
        if let customURL = customURL, let data = try? Data(contentsOf: customURL) {
            if let decoded = try? JSONDecoder().decode([SearchRule].self, from: data) {
                return decoded
            }
        }

        #if SWIFT_PACKAGE
        if let bundleURL = Bundle.module.url(forResource: "search_rules", withExtension: "json"),
           let data = try? Data(contentsOf: bundleURL),
           let decoded = try? JSONDecoder().decode([SearchRule].self, from: data) {
            return decoded
        }
        #endif

        return defaultRules
    }

    /// Hardcoded fallback in case resource bundle lookup is unavailable in specific test setups
    public static let defaultRules: [SearchRule] = [
        SearchRule(id: "user_app_support", name: "Application Support", domain: "user", pathTemplate: "~/Library/Application Support", matchStrategy: "bundleIdOrName", requiresPrivilege: false),
        SearchRule(id: "user_caches", name: "Caches", domain: "user", pathTemplate: "~/Library/Caches", matchStrategy: "bundleIdOrName", requiresPrivilege: false),
        SearchRule(id: "user_preferences", name: "Preferences", domain: "user", pathTemplate: "~/Library/Preferences", matchStrategy: "plistPreferences", requiresPrivilege: false),
        SearchRule(id: "user_containers", name: "Containers", domain: "user", pathTemplate: "~/Library/Containers", matchStrategy: "bundleIdOrName", requiresPrivilege: false),
        SearchRule(id: "user_group_containers", name: "Group Containers", domain: "user", pathTemplate: "~/Library/Group Containers", matchStrategy: "bundleIdOrName", requiresPrivilege: false),
        SearchRule(id: "user_saved_state", name: "Saved Application State", domain: "user", pathTemplate: "~/Library/Saved Application State", matchStrategy: "savedState", requiresPrivilege: false),
        SearchRule(id: "user_logs", name: "Logs", domain: "user", pathTemplate: "~/Library/Logs", matchStrategy: "bundleIdOrName", requiresPrivilege: false),
        SearchRule(id: "user_http_storages", name: "HTTP Storages", domain: "user", pathTemplate: "~/Library/HTTPStorages", matchStrategy: "bundleIdOrName", requiresPrivilege: false),
        SearchRule(id: "user_webkit", name: "WebKit", domain: "user", pathTemplate: "~/Library/WebKit", matchStrategy: "bundleIdOrName", requiresPrivilege: false),
        SearchRule(id: "user_cookies", name: "Cookies", domain: "user", pathTemplate: "~/Library/Cookies", matchStrategy: "bundleIdOrName", requiresPrivilege: false),
        SearchRule(id: "user_launch_agents", name: "Launch Agents", domain: "user", pathTemplate: "~/Library/LaunchAgents", matchStrategy: "launchAgentOrDaemon", requiresPrivilege: false),
        SearchRule(id: "user_app_scripts", name: "Application Scripts", domain: "user", pathTemplate: "~/Library/Application Scripts", matchStrategy: "bundleIdOrName", requiresPrivilege: false),
        SearchRule(id: "system_app_support", name: "System Application Support", domain: "system", pathTemplate: "/Library/Application Support", matchStrategy: "bundleIdOrName", requiresPrivilege: true),
        SearchRule(id: "system_caches", name: "System Caches", domain: "system", pathTemplate: "/Library/Caches", matchStrategy: "bundleIdOrName", requiresPrivilege: true),
        SearchRule(id: "system_preferences", name: "System Preferences", domain: "system", pathTemplate: "/Library/Preferences", matchStrategy: "plistPreferences", requiresPrivilege: true),
        SearchRule(id: "system_launch_agents", name: "System Launch Agents", domain: "system", pathTemplate: "/Library/LaunchAgents", matchStrategy: "launchAgentOrDaemon", requiresPrivilege: true),
        SearchRule(id: "system_launch_daemons", name: "System Launch Daemons", domain: "system", pathTemplate: "/Library/LaunchDaemons", matchStrategy: "launchAgentOrDaemon", requiresPrivilege: true),
        SearchRule(id: "system_privileged_helpers", name: "Privileged Helper Tools", domain: "system", pathTemplate: "/Library/PrivilegedHelperTools", matchStrategy: "bundleIdOrName", requiresPrivilege: true),
        SearchRule(id: "darwin_user_cache", name: "Darwin User Cache Directory", domain: "darwin_cache", pathTemplate: "$DARWIN_USER_CACHE_DIR", matchStrategy: "bundleIdOrName", requiresPrivilege: false),
        SearchRule(id: "darwin_user_temp", name: "Darwin User Temp Directory", domain: "darwin_temp", pathTemplate: "$DARWIN_USER_TEMP_DIR", matchStrategy: "bundleIdOrName", requiresPrivilege: false)
    ]
}
