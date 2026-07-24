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
      isPairingHost(url.host),
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

  /// Accepts the canonical `pair` host and the legacy `remote-pair` host so
  /// links handed out before the hosts were unified still resolve.
  private static func isPairingHost(_ host: String?) -> Bool {
    guard let host = host?.lowercased() else {
      return false
    }
    return host == "pair" || host == "remote-pair"
  }

  /// True when `url` is an unambiguous remote-daemon pairing link: a `harness://`
  /// pairing host whose payload carries the remote marker `server_spki_sha256`
  /// and not the relay marker `publicKeyFingerprint`. The flow is chosen from
  /// the payload, not the host — the `pair` host is shared with relay
  /// invitations. A payload carrying both markers is ambiguous and left for the
  /// router rather than decoded as remote, since `Codable` decoding would
  /// otherwise ignore the relay marker and accept it. A remote payload that is
  /// otherwise malformed still returns true so the caller surfaces a clear
  /// pairing error; a payload without the remote marker is left for the router.
  public static func isRemotePairingLink(_ url: URL) -> Bool {
    guard
      url.scheme?.lowercased() == "harness",
      isPairingHost(url.host),
      let object = payloadObject(from: url)
    else {
      return false
    }
    return object["server_spki_sha256"] != nil && object["publicKeyFingerprint"] == nil
  }

  private static func payloadObject(from url: URL) -> [String: Any]? {
    guard
      let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first(where: { $0.name == "payload" })?
        .value
    else {
      return nil
    }
    let padding = String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    let base64 =
      encoded
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/") + padding
    guard
      let data = Data(base64Encoded: base64),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    return object
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
