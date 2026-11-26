import Foundation

public final class HomebrewResolver {
    private let reader: HomebrewReading

    public init(reader: HomebrewReading = HomebrewReader.shared) {
        self.reader = reader
    }

    public func listInstalledPackages(
        kind: HomebrewPackageKind? = nil,
        leavesOnly: Bool = false,
        outdatedOnly: Bool = false,
        filter: String? = nil
    ) throws -> [HomebrewPackageInfo] {
        let all = try reader.installedPackages()
        let query = filter?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let filtered = all.filter { pkg in
            if let kind = kind, pkg.kind != kind { return false }
            if leavesOnly && (!pkg.installedOnRequest || !pkg.requiredBy.isEmpty) { return false }
            if outdatedOnly && !pkg.isOutdated { return false }

            if let q = query, !q.isEmpty {
                let matches =
                    pkg.name.lowercased().contains(q) ||
                    pkg.fullName.lowercased().contains(q) ||
                    pkg.displayNames.contains(where: { $0.lowercased().contains(q) }) ||
                    pkg.aliases.contains(where: { $0.lowercased().contains(q) }) ||
                    (pkg.descriptionText?.lowercased().contains(q) ?? false)
                if !matches { return false }
            }
            return true
        }

        return filtered.sorted { lhs, rhs in
            let cmp = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if cmp != .orderedSame {
                return cmp == .orderedAscending
            }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
    }

    public func resolve(target: String, preferredKind: HomebrewPackageKind? = nil) throws -> HomebrewPackageInfo {
        var clean = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if (clean.hasPrefix("\"") && clean.hasSuffix("\"")) || (clean.hasPrefix("'") && clean.hasSuffix("'")) {
            clean = String(clean.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !clean.isEmpty else {
            throw SweepError.invalidPath(target)
        }

        let all = try reader.installedPackages().filter { preferredKind == nil || $0.kind == preferredKind }
        let lower = clean.lowercased()

        // 1. Exact fullName match (e.g. hamimlohani/tap/sweep)
        let exactFull = all.filter { $0.fullName.lowercased() == lower }
        if exactFull.count == 1 { return exactFull[0] }
        if exactFull.count > 1 {
            throw SweepError.ambiguousPackage(target, exactFull.map { "\($0.fullName) (\($0.kind.rawValue))" })
        }

        // 2. Exact name/token match
        let exactName = all.filter { $0.name.lowercased() == lower }
        if exactName.count == 1 { return exactName[0] }
        if exactName.count > 1 {
            throw SweepError.ambiguousPackage(target, exactName.map { "\($0.fullName) (\($0.kind.rawValue)) — pass --formula or --cask" })
        }

        // 3. Exact alias, oldName, or cask display name match
        let aliasMatches = all.filter { pkg in
            pkg.aliases.contains(where: { $0.lowercased() == lower }) ||
            pkg.oldNames.contains(where: { $0.lowercased() == lower }) ||
            pkg.displayNames.contains(where: { $0.lowercased() == lower })
        }
        if aliasMatches.count == 1 { return aliasMatches[0] }
        if aliasMatches.count > 1 {
            throw SweepError.ambiguousPackage(target, aliasMatches.map { "\($0.fullName) (\($0.kind.rawValue))" })
        }

        // 4. Unique substring match
        let subMatches = all.filter { pkg in
            pkg.name.lowercased().contains(lower) ||
            pkg.fullName.lowercased().contains(lower) ||
            pkg.displayNames.contains(where: { $0.lowercased().contains(lower) })
        }
        if subMatches.count == 1 { return subMatches[0] }
        if subMatches.count > 1 {
            throw SweepError.ambiguousPackage(target, subMatches.map { "\($0.fullName) (\($0.kind.rawValue))" })
        }

        throw SweepError.packageNotFound(target)
    }
}
