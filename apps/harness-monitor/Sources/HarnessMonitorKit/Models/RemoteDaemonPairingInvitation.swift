import Foundation

public enum RemoteDaemonPairingInvitationError: LocalizedError, Equatable {
  case invalidURL
  case invalidPayload
  case unsupportedVersion(Int)
  case invalidEndpoint
  case missingCode
  case expired

  public var errorDescription: String? {
    switch self {
    case .invalidURL:
      "The remote pairing link is invalid"
    case .invalidPayload:
      "The remote pairing payload is invalid"
    case .unsupportedVersion(let version):
      "Remote pairing version \(version) is not supported"
    case .invalidEndpoint:
      "The remote pairing endpoint must be an HTTPS origin"
    case .missingCode:
      "The remote pairing code is missing"
    case .expired:
      "The remote pairing code has expired"
    }
  }
}

public struct RemoteDaemonPairingInvitation: Codable, Equatable, Sendable {
  public let version: Int
  public let endpoint: URL
  public let code: String
  public let serverSPKISHA256: RemoteDaemonSPKIPin
  public let role: RemoteDaemonRole
  public let scopes: [String]
  public let expiresAt: Date

  public init(
    endpoint: URL,
    code: String,
    serverSPKISHA256: RemoteDaemonSPKIPin,
    role: RemoteDaemonRole = .admin,
    scopes: [String],
    expiresAt: Date,
    now: Date = .now
  ) throws {
    self.version = 1
    self.endpoint = endpoint
    self.code = code
    self.serverSPKISHA256 = serverSPKISHA256
    self.role = role
    self.scopes = scopes
    self.expiresAt = expiresAt
    try validate(now: now)
  }

  public static func decode(_ url: URL, now: Date = .now) throws -> Self {
    guard
      url.scheme?.lowercased() == "harness",
      url.host?.lowercased() == "remote-pair",
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else {
      throw RemoteDaemonPairingInvitationError.invalidURL
    }
    let payloadValues = components.queryItems?.filter { $0.name == "payload" } ?? []
    guard payloadValues.count == 1, let encoded = payloadValues[0].value else {
      throw RemoteDaemonPairingInvitationError.invalidURL
    }
    let padding = String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    let base64 =
      encoded
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/") + padding
    guard let data = Data(base64Encoded: base64) else {
      throw RemoteDaemonPairingInvitationError.invalidPayload
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let invitation: Self
    do {
      invitation = try decoder.decode(Self.self, from: data)
    } catch {
      throw RemoteDaemonPairingInvitationError.invalidPayload
    }
    try invitation.validate(now: now)
    return invitation
  }

  private func validate(now: Date) throws {
    guard version == 1 else {
      throw RemoteDaemonPairingInvitationError.unsupportedVersion(version)
    }
    do {
      try RemoteDaemonEndpointValidator.validate(endpoint)
    } catch {
      throw RemoteDaemonPairingInvitationError.invalidEndpoint
    }
    guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw RemoteDaemonPairingInvitationError.missingCode
    }
    guard
      !scopes.isEmpty,
      scopes.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    else {
      throw RemoteDaemonPairingInvitationError.invalidPayload
    }
    guard expiresAt > now else {
      throw RemoteDaemonPairingInvitationError.expired
    }
  }

  enum CodingKeys: String, CodingKey {
    case version
    case endpoint
    case code
    case serverSPKISHA256 = "server_spki_sha256"
    case role
    case scopes
    case expiresAt = "expires_at"
  }
}
