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
      Self.userFacingServerErrorDescription(code: code, message: message)
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

  public var serverMessage: String? {
    guard case .server(_, let message) = self else {
      return nil
    }
    return Self.normalizedServerMessage(from: message)
  }

  public var serverSemanticCode: String? {
    guard case .server(_, let message) = self else {
      return nil
    }
    return Self.parsedServerEnvelope(from: message)?.error.code
  }

  private static func userFacingServerErrorDescription(code: Int, message: String) -> String {
    if let flatEnvelope = parsedFlatServerEnvelope(from: message),
      flatEnvelope.error == "sandbox-disabled"
    {
      return sandboxDisabledDescription(feature: flatEnvelope.feature)
    }

    return "Daemon error \(code): \(Self.normalizedServerMessage(from: message))"
  }

  private static func sandboxDisabledDescription(feature: String?) -> String {
    switch feature {
    case "acp.host-bridge":
      """
      ACP sessions can't make tool calls because the shared host bridge isn't \
      running. Start the host bridge and try again.
      """
    case "agent-tui.host-bridge":
      """
      Terminal agents can't start because the shared host bridge isn't running. \
      Start the host bridge and try again.
      """
    case "codex.host-bridge":
      "Codex can't start because the shared host bridge isn't running. Start the host bridge and try again."
    default:
      "This action isn't available because the required bridge isn't running. Start the bridge and try again."
    }
  }

  private static func normalizedServerMessage(from message: String) -> String {
    guard let envelope = parsedServerEnvelope(from: message) else {
      return message
    }

    let normalized = envelope.error.message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      return message
    }
    return normalized
  }

  private static func parsedServerEnvelope(from message: String) -> ParsedServerEnvelope? {
    guard let data = message.data(using: .utf8) else {
      return nil
    }
    return try? JSONDecoder().decode(ParsedServerEnvelope.self, from: data)
  }

  private static func parsedFlatServerEnvelope(from message: String) -> ParsedFlatServerEnvelope? {
    guard let data = message.data(using: .utf8) else {
      return nil
    }
    if let envelope = try? JSONDecoder().decode(ParsedFlatServerEnvelope.self, from: data) {
      return envelope
    }

    let parts = message.components(separatedBy: " - ")
    guard let firstPart = parts.first else {
      return nil
    }
    let error = firstPart.trimmingCharacters(in: .whitespacesAndNewlines)
    guard error == "sandbox-disabled" else {
      return nil
    }
    let feature =
      parts.dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines)
    return ParsedFlatServerEnvelope(error: error, feature: feature)
  }

  private struct ParsedServerEnvelope: Decodable {
    let error: ParsedServerError
  }

  private struct ParsedServerError: Decodable {
    let code: String?
    let message: String
  }

  private struct ParsedFlatServerEnvelope: Decodable {
    let error: String
    let feature: String?
  }
}
