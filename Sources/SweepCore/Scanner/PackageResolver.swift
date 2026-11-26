import Foundation

public final class PackageResolver {
    private let receiptReader: ReceiptReading

    public init(receiptReader: ReceiptReading = ReceiptReader.shared) {
        self.receiptReader = receiptReader
    }

    /// Lists installed macOS installer packages from the receipt database.
    public func listInstalledPackages(includeApple: Bool = false, filter: String? = nil) -> [PackageInfo] {
        let allIDs = receiptReader.allPackages()
        let filterQuery = filter?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var results: [PackageInfo] = []
        for pkgID in allIDs {
            let isApple = pkgID.lowercased().hasPrefix("com.apple.")
            if !includeApple && isApple {
                continue
            }

            let info = receiptReader.packageInfo(for: pkgID, includeGroups: false) ?? PackageInfo(
                packageIdentifier: pkgID,
                version: nil
            )

            if let query = filterQuery, !query.isEmpty {
                let matchesID = info.packageIdentifier.lowercased().contains(query)
                let matchesFile = info.packageFileName?.lowercased().contains(query) ?? false
                let matchesDisplay = info.displayName.lowercased().contains(query)
                guard matchesID || matchesFile || matchesDisplay else { continue }
            }

            results.append(info)
        }

        return results.sorted {
            $0.packageIdentifier.localizedCaseInsensitiveCompare($1.packageIdentifier) == .orderedAscending
        }
    }

    /// Resolves a package identifier, installer filename, or unique partial query to a `PackageInfo`.
    public func resolve(target: String) throws -> PackageInfo {
        var clean = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if (clean.hasPrefix("\"") && clean.hasSuffix("\"")) || (clean.hasPrefix("'") && clean.hasSuffix("'")) {
            clean = String(clean.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !clean.isEmpty else {
            throw SweepError.invalidPath(target)
        }

        let allIDs = receiptReader.allPackages()
        let lower = clean.lowercased()

        // 1. Exact package identifier match (case-insensitive)
        if let exactID = allIDs.first(where: { $0.lowercased() == lower }) {
            return receiptReader.packageInfo(for: exactID, includeGroups: true)
                ?? PackageInfo(packageIdentifier: exactID, version: nil)
        }

        // Partition into non-Apple and Apple packages so third-party packages are checked first
        let thirdPartyPackages = listInstalledPackages(includeApple: false)
        if let resolved = try matchPackage(query: clean, in: thirdPartyPackages) {
            return receiptReader.packageInfo(for: resolved.packageIdentifier, includeGroups: true) ?? resolved
        }

        // Fall back to Apple packages if no third-party package matched
        let appleOnly = allIDs
            .filter { $0.lowercased().hasPrefix("com.apple.") }
            .compactMap { receiptReader.packageInfo(for: $0, includeGroups: false) }
        if let resolved = try matchPackage(query: clean, in: appleOnly) {
            return receiptReader.packageInfo(for: resolved.packageIdentifier, includeGroups: true) ?? resolved
        }

        throw SweepError.packageNotFound(target)
    }

    private func matchPackage(query: String, in candidates: [PackageInfo]) throws -> PackageInfo? {
        let lower = query.lowercased()
        let strippedPkg = lower.hasSuffix(".pkg") ? String(lower.dropLast(4)) : lower

        // 2A. Exact installer filename match (with or without .pkg)
        let filenameMatches = candidates.filter { pkg in
            guard let fname = pkg.packageFileName?.lowercased() else { return false }
            let strippedFile = fname.hasSuffix(".pkg") ? String(fname.dropLast(4)) : fname
            return fname == lower || strippedFile == strippedPkg
        }
        if filenameMatches.count == 1 { return filenameMatches[0] }
        if filenameMatches.count > 1 {
            throw SweepError.ambiguousPackage(query, filenameMatches.map { $0.packageIdentifier })
        }

        // 2B. Exact trailing component match (e.g. "ChmodBPF" -> "org.wireshark.ChmodBPF.pkg")
        let segmentMatches = candidates.filter { pkg in
            var parts = pkg.packageIdentifier.lowercased().split(separator: ".").map(String.init)
            if parts.last == "pkg" || parts.last == "app" {
                parts.removeLast()
            }
            return parts.last == strippedPkg
        }
        if segmentMatches.count == 1 { return segmentMatches[0] }
        if segmentMatches.count > 1 {
            throw SweepError.ambiguousPackage(query, segmentMatches.map { $0.packageIdentifier })
        }

        // 2C. Substring match on package identifier, display name, or filename
        let substringMatches = candidates.filter { pkg in
            pkg.packageIdentifier.lowercased().contains(lower) ||
            pkg.displayName.lowercased().contains(lower) ||
            (pkg.packageFileName?.lowercased().contains(lower) ?? false)
        }
        if substringMatches.count == 1 { return substringMatches[0] }
        if substringMatches.count > 1 {
            throw SweepError.ambiguousPackage(query, substringMatches.map { $0.packageIdentifier })
        }

        return nil
    }
}
