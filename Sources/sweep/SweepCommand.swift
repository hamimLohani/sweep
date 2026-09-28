import ArgumentParser
import Foundation

public struct SweepCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sweep",
        abstract: "Clean and safe macOS application uninstaller.",
        discussion: """
        Finds and safely removes applications along with their hidden leftover
        preferences, caches, application support files, launch agents, and helpers.
        """,
        version: "sweep 1.0.2",
        subcommands: [
            ListCommand.self,
            ScanCommand.self,
            RemoveCommand.self,
            DoctorCommand.self
        ]
    )

    public init() {}
}
