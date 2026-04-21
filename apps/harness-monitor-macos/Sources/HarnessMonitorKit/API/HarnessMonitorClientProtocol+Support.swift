import Foundation

public struct HarnessMonitorConnection: Equatable, Sendable {
  public let endpoint: URL
  public let token: String

  public init(endpoint: URL, token: String) {
    self.endpoint = endpoint
    self.token = token
  }
}

public enum HarnessMonitorAPIError: Error, LocalizedError, Equatable {
  case invalidEndpoint(String)
  case invalidResponse
  case server(code: Int, message: String)
  case adoptAlreadyAttached(sessionId: String)
  case adoptLayoutViolation(reason: String)
  case adoptOriginMismatch(expected: String, found: String)
  case adoptUnsupportedSchemaVersion(found: Int, supported: Int)

  public var errorDescription: String? {
    switch self {
    case .invalidEndpoint(let value):
      "Invalid daemon endpoint: \(value)"
    case .invalidResponse:
      "The daemon returned an invalid response."
    case .server(let code, let message):
      "Daemon error \(code): \(message)"
    case .adoptAlreadyAttached(let sessionId):
      "Session \(sessionId) is already attached."
    case .adoptLayoutViolation(let reason):
      "Not a harness session: \(reason)"
    case .adoptOriginMismatch(let expected, let found):
      "Origin mismatch: expected \(expected), found \(found)"
    case .adoptUnsupportedSchemaVersion(let found, let supported):
      "Unsupported schema version \(found); this version supports \(supported)."
    }
  }
}
