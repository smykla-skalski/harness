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

  public var errorDescription: String? {
    switch self {
    case .invalidEndpoint(let value):
      "Invalid daemon endpoint: \(value)"
    case .invalidResponse:
      "The daemon returned an invalid response."
    case .server(let code, let message):
      "Daemon error \(code): \(message)"
    }
  }
}
