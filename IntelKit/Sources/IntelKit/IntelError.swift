import Foundation

/// A failure from the store, an importer, or the GDELT client.
public enum IntelError: Error, Equatable, CustomStringConvertible, Sendable {
    /// A record violated a model rule (empty name, half a coordinate pair, inverted time).
    case validation(String)
    /// A query named an entity or link that is not in the store.
    case notFound(String)
    /// CSV or JSON did not match the importer's shape.
    case malformedImport(String)
    /// A GDELT response or request could not be used.
    case gdelt(String)
    /// SQLite reported an error. The message is the database's, with no extra context added.
    case database(String)

    public var description: String {
        switch self {
        case .validation(let message),
            .notFound(let message),
            .malformedImport(let message),
            .gdelt(let message),
            .database(let message):
            return message
        }
    }
}
