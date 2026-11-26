import Foundation

/// Standardized exit codes conforming to the tool specifications:
/// - 0: success
/// - 1: general error
/// - 2: usage error
/// - 3: permission error
/// - 4: app not found
public enum SweepExitCode: Int32 {
    case success = 0
    case generalError = 1
    case usageError = 2
    case permissionError = 3
    case appNotFound = 4
}

public enum SweepError: LocalizedError {
    case appNotFound(String)
    case packageNotFound(String)
    case ambiguousPackage(String, [String])
    case permissionDenied(String)
    case protectedSystemComponent(String)
    case invalidPath(String)
    case runningAppRefusedQuit(String)
    case executionFailed(String)
    case general(String)

    public var exitCode: SweepExitCode {
        switch self {
        case .appNotFound, .packageNotFound:
            return .appNotFound
        case .permissionDenied, .protectedSystemComponent:
            return .permissionError
        case .invalidPath, .ambiguousPackage:
            return .usageError
        case .runningAppRefusedQuit, .executionFailed, .general:
            return .generalError
        }
    }

    public var errorDescription: String? {
        switch self {
        case .appNotFound(let target):
            return "Application not found: '\(target)'."
        case .packageNotFound(let target):
            return "Package not found: '\(target)'."
        case .ambiguousPackage(let target, let candidates):
            let listed = candidates.prefix(10).map { "  - \($0)" }.joined(separator: "\n")
            let extra = candidates.count > 10 ? "\n  ... and \(candidates.count - 10) more" : ""
            return "Multiple packages match '\(target)':\n\(listed)\(extra)\nSpecify the exact package identifier."
        case .permissionDenied(let details):
            return "Permission denied: \(details)"
        case .protectedSystemComponent(let details):
            return "Protected system component: \(details)"
        case .invalidPath(let path):
            return "Invalid path specified: '\(path)'."
        case .runningAppRefusedQuit(let app):
            return "Application '\(app)' is currently running and could not be stopped."
        case .executionFailed(let reason):
            return "Execution failed: \(reason)"
        case .general(let message):
            return message
        }
    }
}
