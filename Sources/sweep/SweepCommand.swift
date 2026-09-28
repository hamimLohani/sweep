import ArgumentParser
import Foundation

public struct SweepCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sweep",
        abstract: "Clean and safe macOS application uninstaller.",
        discussion: """
        Finds and safely removes applications along with their hidden leftover
        preferences, caches, application support files, launch agents, and helpers.

        COMMON COMMANDS:
          sweep list                  List installed applications
          sweep scan <app>            Inspect leftovers without deleting
          sweep remove <app>          Uninstall an application and its leftovers
          sweep remove cache <app>    Purge cache files for an app (e.g. Safari) or 'all'
          sweep doctor                Check system permissions and health
        """,
        version: "sweep 1.0.6",
        subcommands: [
            ListCommand.self,
            ScanCommand.self,
            RemoveCommand.self,
            DoctorCommand.self
        ]
    )

    public init() {}
}
