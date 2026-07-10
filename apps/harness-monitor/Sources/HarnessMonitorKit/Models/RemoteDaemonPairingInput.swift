import Foundation

public enum RemoteDaemonPairingInput: Equatable, Sendable {
  case deepLink(String)
  case manual(endpoint: String, code: String, serverSPKISHA256: String)

  public func invitation(now: Date = .now) throws -> RemoteDaemonPairingInvitation {
    switch self {
    case .deepLink(let rawValue):
      let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let url = URL(string: trimmed) else {
        throw RemoteDaemonPairingInvitationError.invalidURL
      }
      return try RemoteDaemonPairingInvitation.decode(url, now: now)
    case .manual(let endpointValue, let codeValue, let pinValue):
      let endpointValue = endpointValue.trimmingCharacters(in: .whitespacesAndNewlines)
      let code = codeValue.trimmingCharacters(in: .whitespacesAndNewlines)
      let pinValue = pinValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let endpoint = URL(string: endpointValue) else {
        throw RemoteDaemonPairingInvitationError.invalidEndpoint
      }
      return try RemoteDaemonPairingInvitation(
        endpoint: endpoint,
        code: code,
        serverSPKISHA256: RemoteDaemonSPKIPin(validating: pinValue),
        role: .viewer,
        scopes: ["pair:claim"],
        expiresAt: now.addingTimeInterval(600),
        now: now
      )
    }
  }
}
