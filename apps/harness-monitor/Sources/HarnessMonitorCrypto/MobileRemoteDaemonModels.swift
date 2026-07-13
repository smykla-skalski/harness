import Foundation
import HarnessMonitorCore

public enum MobileRemoteDaemonRole: String, Codable, CaseIterable, Sendable {
  case admin
  case `operator`
  case viewer
}

public enum MobileRemoteDaemonProfileError: Error, Equatable, Sendable {
  case invalidEndpoint
  case invalidInvitation
  case invalidPin
  case expired
  case unsupportedVersion(Int)
}

public struct MobileRemoteDaemonSPKIPin: Codable, Equatable, Hashable, Sendable {
  public let value: String
  public let digest: Data

  public init(validating value: String) throws {
    let prefix = "sha256/"
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix(prefix) else {
      throw MobileRemoteDaemonProfileError.invalidPin
    }
    let compact = String(trimmed.dropFirst(prefix.count).filter { !$0.isWhitespace })
    let remainder = compact.count % 4
    guard remainder != 1 else {
      throw MobileRemoteDaemonProfileError.invalidPin
    }
    let padded = compact + String(repeating: "=", count: (4 - remainder) % 4)
    guard let digest = Data(base64Encoded: padded), digest.count == 32 else {
      throw MobileRemoteDaemonProfileError.invalidPin
    }
    self.value = prefix + digest.base64EncodedString()
    self.digest = digest
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(validating: container.decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value)
  }
}

public struct MobileRemoteDaemonAccess: Codable, Equatable, Sendable, CustomStringConvertible {
  public var endpoint: URL
  public var clientID: String
  public var displayName: String
  public var platform: String
  public var role: MobileRemoteDaemonRole
  public var scopes: [String]
  public var bearerToken: String
  public var tokenHint: String
  public var serverSPKISHA256: MobileRemoteDaemonSPKIPin
  public var pairedAt: Date
  public var reviewsQuery: MobileRemoteDaemonReviewsQuery?
  public var deviceIdentityID: String?

  public init(
    endpoint: URL,
    clientID: String,
    displayName: String,
    platform: String,
    role: MobileRemoteDaemonRole,
    scopes: [String],
    bearerToken: String,
    tokenHint: String,
    serverSPKISHA256: MobileRemoteDaemonSPKIPin,
    pairedAt: Date,
    reviewsQuery: MobileRemoteDaemonReviewsQuery? = nil,
    deviceIdentityID: String? = nil
  ) {
    self.endpoint = endpoint
    self.clientID = clientID
    self.displayName = displayName
    self.platform = platform
    self.role = role
    self.scopes = scopes
    self.bearerToken = bearerToken
    self.tokenHint = tokenHint
    self.serverSPKISHA256 = serverSPKISHA256
    self.pairedAt = pairedAt
    self.reviewsQuery = reviewsQuery
    self.deviceIdentityID = deviceIdentityID
  }

  public var description: String {
    "MobileRemoteDaemonAccess(endpoint: \(endpoint.absoluteString), clientID: \(clientID), "
      + "platform: \(platform), role: \(role.rawValue), scopes: \(scopes), "
      + "tokenHint: \(tokenHint), reviewsQuery: \(reviewsQuery == nil ? "none" : "configured"), "
      + "deviceIdentityID: \(deviceIdentityID ?? "legacy"), "
      + "bearerToken: <redacted>)"
  }

  public var canRead: Bool {
    role == .admin || scopes.contains("read")
  }

  public var canWrite: Bool {
    role == .admin || scopes.contains("write")
  }
}

public struct MobileRemoteDaemonPairingInvitation: Codable, Equatable, Sendable {
  public let version: Int
  public let endpoint: URL
  public let code: String
  public let serverSPKISHA256: MobileRemoteDaemonSPKIPin
  public let role: MobileRemoteDaemonRole
  public let scopes: [String]
  public let expiresAt: Date

  public static func decode(_ url: URL, now: Date = .now) throws -> Self {
    guard MobilePairingLink.supports(url), url.host?.lowercased() == "remote-pair" else {
      throw MobileRemoteDaemonProfileError.invalidInvitation
    }
    let payloads =
      URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .queryItems?
      .filter { $0.name == "payload" } ?? []
    guard payloads.count == 1,
      let payload = payloads.first?.value,
      let data = Data(base64URLEncoded: payload)
    else {
      throw MobileRemoteDaemonProfileError.invalidInvitation
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let invitation: Self
    do {
      invitation = try decoder.decode(Self.self, from: data)
    } catch {
      throw MobileRemoteDaemonProfileError.invalidInvitation
    }
    try invitation.validate(now: now)
    return invitation
  }

  private func validate(now: Date) throws {
    guard version == 1 else {
      throw MobileRemoteDaemonProfileError.unsupportedVersion(version)
    }
    try MobileRemoteDaemonEndpoint.validate(endpoint)
    guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !scopes.isEmpty,
      scopes.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    else {
      throw MobileRemoteDaemonProfileError.invalidInvitation
    }
    guard expiresAt > now else {
      throw MobileRemoteDaemonProfileError.expired
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

public enum MobilePairingLink: Equatable, Sendable {
  case relay(MobilePairingInvitation)
  case remote(MobileRemoteDaemonPairingInvitation)

  public static func supports(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == MobilePairingInvitationCodec.urlScheme,
      let host = url.host?.lowercased()
    else {
      return false
    }
    return [MobilePairingInvitationCodec.urlHost, "remote-pair"].contains(host)
  }

  public static func decode(_ url: URL, now: Date = .now) throws -> Self {
    switch url.host?.lowercased() {
    case MobilePairingInvitationCodec.urlHost:
      return .relay(try MobilePairingInvitationCodec.decode(url, now: now))
    case "remote-pair":
      return .remote(try MobileRemoteDaemonPairingInvitation.decode(url, now: now))
    default:
      throw MobilePairingError.unsupportedURL(url.absoluteString)
    }
  }

  public static func normalizedURL(from value: String, now: Date = .now) throws -> URL {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if let url = URL(string: trimmed), url.scheme != nil {
      _ = try decode(url, now: now)
      return url
    }
    guard let data = Data(base64URLEncoded: trimmed),
      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw MobileRemoteDaemonProfileError.invalidInvitation
    }
    if payload["server_spki_sha256"] != nil {
      var components = URLComponents()
      components.scheme = MobilePairingInvitationCodec.urlScheme
      components.host = "remote-pair"
      components.queryItems = [URLQueryItem(name: "payload", value: trimmed)]
      guard let url = components.url else {
        throw MobileRemoteDaemonProfileError.invalidInvitation
      }
      _ = try decode(url, now: now)
      return url
    }
    let invitation = try MobilePairingInvitationCodec.decode(trimmed, now: now)
    return try MobilePairingInvitationCodec.encode(invitation)
  }

  public var stationName: String {
    switch self {
    case .relay(let invitation):
      invitation.stationName
    case .remote(let invitation):
      invitation.endpoint.host ?? invitation.endpoint.absoluteString
    }
  }
}

public enum MobileRemoteDaemonStationID {
  public static func make(endpoint: URL) -> String {
    let host = endpoint.host?.lowercased() ?? "remote"
    let authority = endpoint.port.map { "\(host)-\($0)" } ?? host
    let normalized = authority.map { character in
      character.isLetter || character.isNumber ? character : "-"
    }
    return "remote-" + String(normalized)
  }
}

enum MobileRemoteDaemonEndpoint {
  static func validate(_ endpoint: URL) throws {
    guard endpoint.scheme?.lowercased() == "https",
      endpoint.host?.isEmpty == false,
      endpoint.user == nil,
      endpoint.password == nil,
      endpoint.query == nil,
      endpoint.fragment == nil,
      endpoint.path.isEmpty || endpoint.path == "/"
    else {
      throw MobileRemoteDaemonProfileError.invalidEndpoint
    }
  }
}
