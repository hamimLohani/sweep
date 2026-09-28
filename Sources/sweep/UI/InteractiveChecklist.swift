import Foundation
import SweepCore

public final class InteractiveChecklist {
    /// Prompts the user to review and optionally deselect items before removal
    public static func selectItems(
        candidates: [LeftoverItem],
        includeLowConfidence: Bool,
        autoConfirm: Bool
    ) -> [LeftoverItem]? {
        // Initial selection: include High and Medium by default, include Low only if flag set
        var selectedState: [Bool] = candidates.map { item in
            if item.confidence == .low {
                return includeLowConfidence
            }
            return true
        }

        // If non-interactive or auto-confirmed with --yes, return immediately
        if autoConfirm || !Terminal.isColorEnabled || isatty(STDIN_FILENO) != 1 {
            var result: [LeftoverItem] = []
            for (idx, item) in candidates.enumerated() {
                if selectedState[idx] {
                    result.append(item)
                }
            }
            return result
        }

        // Interactive numbered review loop
        while true {
            print("\n" + Terminal.bold("Review items to remove:"))
            print(Terminal.dim(String(repeating: "─", count: 70)))

            for (i, item) in candidates.enumerated() {
                let num = String(format: "%2d", i + 1)
                let mark = selectedState[i] ? Terminal.colorize("[✓]", .boldGreen) : Terminal.colorize("[ ]", .dim)
                let badge = Formatters.confidenceBadge(item.confidence)
                let path = Formatters.formatPath(item.url)
                let size = Terminal.formatBytes(item.sizeBytes)
                let priv = item.requiresPrivilege ? Terminal.colorize(" [sudo]", .boldRed) : ""

                print("\(num). \(mark) \(badge) \(path) (\(size))\(priv)")
            }

            let selectedCount = selectedState.filter { $0 }.count
            let totalSelectedBytes = candidates.enumerated().reduce(0) { sum, pair in
                selectedState[pair.offset] ? sum + pair.element.sizeBytes : sum
            }

            print(Terminal.dim(String(repeating: "─", count: 70)))
            print("Selected: \(selectedCount)/\(candidates.count) items (\(Terminal.formatBytes(totalSelectedBytes)))")
            print(Terminal.bold("\nCommands: ") + Terminal.dim("[Enter] Proceed | [1-\(candidates.count)] Toggle item | [a] Select all | [n] Select none | [q] Cancel"))
            print(Terminal.bold("Enter choice: "), terminator: "")
            fflush(stdout)

            guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                return nil
            }

            if line.isEmpty || line == "y" || line == "yes" {
                break
            } else if line == "q" || line == "cancel" {
                return nil
            } else if line == "a" || line == "all" {
                selectedState = [Bool](repeating: true, count: candidates.count)
            } else if line == "n" || line == "none" {
                selectedState = [Bool](repeating: false, count: candidates.count)
            } else if let num = Int(line), num >= 1, num <= candidates.count {
                selectedState[num - 1].toggle()
            } else {
                print(Terminal.colorize("Invalid input. Type a number to toggle, or press Enter to proceed.", .yellow))
            }
        }

        var selectedItems: [LeftoverItem] = []
        for (i, item) in candidates.enumerated() {
            if selectedState[i] {
                selectedItems.append(item)
            }
        }
        return selectedItems
    }
}
