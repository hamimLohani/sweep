import Foundation

public struct MatchResult {
    public let confidence: Confidence
    public let reason: String
}

public final class ConfidenceScorer {
    /// Determines if a filename/directory name matches the application and scores its confidence.
    public static func score(
        itemName: String,
        appInfo: AppInfo,
        strategy: String
    ) -> MatchResult? {
        let bundleID = appInfo.bundleIdentifier.lowercased()
        let nameLower = itemName.lowercased()
        let appName = appInfo.bundleName.lowercased()
        let displayName = appInfo.displayName.lowercased()

        // Strip common extensions (.plist, .savedState, etc.) for base comparison
        let strippedName: String
        if nameLower.hasSuffix(".plist") {
            strippedName = String(nameLower.dropLast(6))
        } else if nameLower.hasSuffix(".savedstate") {
            strippedName = String(nameLower.dropLast(11))
        } else {
            strippedName = nameLower
        }

        // 1. HIGH CONFIDENCE: Exact bundle identifier match
        if !bundleID.isEmpty {
            if strippedName == bundleID || nameLower == "\(bundleID).plist" || nameLower == "\(bundleID).savedstate" {
                return MatchResult(confidence: .high, reason: "Exact bundle identifier match (\(appInfo.bundleIdentifier))")
            }
            if nameLower.hasPrefix("\(bundleID).") {
                return MatchResult(confidence: .high, reason: "Bundle identifier sub-component (\(itemName))")
            }
            // Group container format often: <TeamID>.<bundleID>
            if strippedName.hasSuffix(".\(bundleID)") {
                return MatchResult(confidence: .high, reason: "Group container matching bundle ID (\(itemName))")
            }
        }

        // 2. MEDIUM CONFIDENCE: Exact application name match
        // Guard against dangerous false positives for very short names (e.g. "R", "Go", "Up")
        if appName.count >= 3 {
            if strippedName == appName || nameLower == "\(appName).plist" {
                return MatchResult(confidence: .medium, reason: "Exact application name match (\(appInfo.bundleName))")
            }
            if !displayName.isEmpty && displayName.count >= 3 {
                if strippedName == displayName || nameLower == "\(displayName).plist" {
                    return MatchResult(confidence: .medium, reason: "Exact display name match (\(appInfo.displayName))")
                }
            }
        }

        // 3. LOW CONFIDENCE: Vendor token match or helper match
        if let vendor = appInfo.vendorToken?.lowercased(), vendor.count >= 4 {
            if strippedName == vendor || strippedName.hasPrefix("\(vendor).") || strippedName.hasPrefix("\(vendor)_") {
                return MatchResult(confidence: .low, reason: "Vendor token match (\(vendor))")
            }
        }

        // Match "<AppName> Helper" or "<AppName> Crash Reporter"
        if appName.count >= 4 && strippedName.hasPrefix("\(appName) ") {
            return MatchResult(confidence: .low, reason: "Application helper prefix (\(itemName))")
        }

        return nil
    }
}
