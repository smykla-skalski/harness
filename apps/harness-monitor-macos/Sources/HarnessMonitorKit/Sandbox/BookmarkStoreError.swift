import Foundation

public enum BookmarkStoreError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(found: Int, expected: Int)
    case unresolvable(id: String, underlying: String)
    case ioError(String)
    case notFound(id: String)
}
