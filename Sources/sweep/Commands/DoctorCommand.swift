import ArgumentParser
import Foundation
import SweepCore

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check permissions, Full Disk Access (FDA), and macOS compatibility."
    )

    func run() throws {
        print(Terminal.bold("Running System & Environment Diagnostics for sweep...\n"))

        let doctor = Doctor()
        let checks = doctor.runDiagnostics()

        var hasFailures = false

        for check in checks {
            let statusBadge = check.passed
                ? Terminal.colorize("✓ PASS", .boldGreen)
                : Terminal.colorize("✖ WARN", .boldYellow)

            print("\(statusBadge) " + Terminal.bold(check.name))
            print("       " + check.message)

            if let remediation = check.remediation {
                print(Terminal.colorize("       🔧 Fix: ", .cyan) + remediation)
            }
            print()

            if !check.passed {
                hasFailures = true
            }
        }

        print(Terminal.dim(String(repeating: "─", count: 70)))
        if hasFailures {
            print(Terminal.colorize("Diagnostic completed with recommendations. Review the warnings above for optimal operation.", .boldYellow))
        } else {
            print(Terminal.colorize("All checks passed! Your system environment is fully configured for sweep.", .boldGreen))
        }
    }
}
