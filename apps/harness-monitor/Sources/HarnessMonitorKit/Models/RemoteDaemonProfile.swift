import Foundation

public enum RemoteDaemonRole: String, Codable, CaseIterable, Sendable {
  case admin
  case `operator`
  case viewer
}

public enum RemoteDaemonProfileStatus: String, Codable, Sendable {
  case active
  case revoked
}

public enum RemoteDaemonSPKIPinError: LocalizedError, Equatable {
  case invalidFormat

  public var errorDescription: String? {
    "The remote daemon SPKI pin is invalid"
  }
}

public struct RemoteDaemonSPKIPin: Codable, Equatable, Hashable, Sendable {
  public let value: String
  public let digest: Data

  public init(validating value: String) throws {
    let prefix = "sha256/"
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.hasPrefix(prefix) else {
      throw RemoteDaemonSPKIPinError.invalidFormat
    }
    let compactDigest = String(value.dropFirst(prefix.count).filter { !$0.isWhitespace })
    let remainder = compactDigest.count % 4
    guard remainder != 1 else {
      throw RemoteDaemonSPKIPinError.invalidFormat
    }
    let encodedDigest = compactDigest + String(repeating: "=", count: (4 - remainder) % 4)
    guard
      let digest = Data(base64Encoded: encodedDigest),
      digest.count == 32
    else {
      throw RemoteDaemonSPKIPinError.invalidFormat
    }
    self.value = prefix + digest.base64EncodedString()
    self.digest = digest
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(validating: container.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value)
  }
}

public struct RemoteDaemonProfile: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let endpoint: URL
  public let clientID: String
  public let displayName: String
  public let platform: String
  public let role: RemoteDaemonRole
  public let scopes: [String]
  public let serverSPKISHA256: RemoteDaemonSPKIPin
  public let tokenHint: String
  public let pairedAt: Date
  public let pairingExpiresAt: Date
  public let status: RemoteDaemonProfileStatus
  public let revokedAt: Date?

  public init(
    id: UUID,
    endpoint: URL,
    clientID: String,
    displayName: String,
    platform: String,
    role: RemoteDaemonRole,
    scopes: [String],
    serverSPKISHA256: RemoteDaemonSPKIPin,
    tokenHint: String,
    pairedAt: Date,
    pairingExpiresAt: Date,
    status: RemoteDaemonProfileStatus,
    revokedAt: Date?
  ) {
    self.id = id
    self.endpoint = endpoint
    self.clientID = clientID
    self.displayName = displayName
    self.platform = platform
    self.role = role
    self.scopes = scopes
    self.serverSPKISHA256 = serverSPKISHA256
    self.tokenHint = tokenHint
    self.pairedAt = pairedAt
    self.pairingExpiresAt = pairingExpiresAt
    self.status = status
    self.revokedAt = revokedAt
  }

  func validated() throws -> Self {
    try RemoteDaemonEndpointValidator.validate(endpoint)
    guard
      !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !platform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !scopes.isEmpty,
      scopes.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    else {
      throw RemoteDaemonProfileError.invalidProfile
    }
    return self
  }

  func markingRevoked(at date: Date) -> Self {
    Self(
      id: id,
      endpoint: endpoint,
      clientID: clientID,
      displayName: displayName,
      platform: platform,
      role: role,
      scopes: scopes,
      serverSPKISHA256: serverSPKISHA256,
      tokenHint: tokenHint,
      pairedAt: pairedAt,
      pairingExpiresAt: pairingExpiresAt,
      status: .revoked,
      revokedAt: date
    )
  }
}

public struct RemoteDaemonProfileState: Codable, Equatable, Sendable {
  public let version: Int
  public var profiles: [RemoteDaemonProfile]
  public var activeProfileID: UUID?

  public init(
    version: Int = 1,
    profiles: [RemoteDaemonProfile] = [],
    activeProfileID: UUID? = nil
  ) {
    self.version = version
    self.profiles = profiles
    self.activeProfileID = activeProfileID
  }

  func validated() throws -> Self {
    guard version == 1, Set(profiles.map(\.id)).count == profiles.count else {
      throw RemoteDaemonProfileError.invalidProfile
    }
    for profile in profiles {
      _ = try profile.validated()
    }
    if let activeProfileID, !profiles.contains(where: { $0.id == activeProfileID }) {
      throw RemoteDaemonProfileError.profileNotFound
    }
    return self
  }
}

enum RemoteDaemonEndpointValidator {
  static func validate(_ endpoint: URL) throws {
    guard
      endpoint.scheme?.lowercased() == "https",
      endpoint.host?.isEmpty == false,
      endpoint.user == nil,
      endpoint.password == nil,
      endpoint.query == nil,
      endpoint.fragment == nil,
      endpoint.path.isEmpty || endpoint.path == "/"
    else {
      throw RemoteDaemonProfileError.invalidEndpoint
    }
  }
}
