import ArgumentParser
import Foundation
import SweepCore

do {
    var command = try SweepCommand.parseAsRoot()
    try command.run()
} catch let error as SweepError {
    fputs(Terminal.colorize("Error: ", .boldRed) + (error.errorDescription ?? "\(error)") + "\n", stderr)
    Foundation.exit(error.exitCode.rawValue)
} catch {
    SweepCommand.exit(withError: error)
}
