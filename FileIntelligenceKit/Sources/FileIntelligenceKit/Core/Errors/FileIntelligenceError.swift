import Foundation

public enum FileIntelligenceError: Error, LocalizedError, Equatable, Sendable {
    case protectedLocation(String)
    case locationAlreadyIndexed(String)
    case locationNotFound(String)
    case notADirectory(String)
    case rootNotFound(Int64)
    case fileNotFound(Int64)
    case categoryNotFound(Int64)
    case timedOut
    case invalidInput(String)

    public var errorDescription: String? {
        switch self {
        case .protectedLocation(let path):
            return "“\(path)” is a protected system location and can’t be indexed."
        case .locationAlreadyIndexed(let path):
            return "“\(path)” is already an indexed location."
        case .locationNotFound(let path):
            return "“\(path)” could not be found."
        case .notADirectory(let path):
            return "“\(path)” is not a folder."
        case .rootNotFound:
            return "The indexed location no longer exists."
        case .fileNotFound:
            return "The file is no longer in the index."
        case .categoryNotFound:
            return "The category no longer exists."
        case .timedOut:
            return "The operation took too long and was stopped."
        case .invalidInput(let message):
            return message
        }
    }
}
