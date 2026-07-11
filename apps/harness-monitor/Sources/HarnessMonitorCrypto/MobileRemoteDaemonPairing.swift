import Foundation

public struct MobileRemoteDaemonPairingClaim: Equatable, Sendable {
  public var clientID: String
  public var displayName: String
  public var platform: String
  public var role: MobileRemoteDaemonRole
  public var scopes: [String]
  public var token: String
  public var tokenHint: String
  public var pairedAt: Date

  public init(
    clientID: String,
    displayName: String,
    platform: String,
    role: MobileRemoteDaemonRole,
    scopes: [String],
    token: String,
    tokenHint: String,
    pairedAt: Date
  ) {
    self.clientID = clientID
    self.displayName = displayName
    self.platform = platform
    self.role = role
    self.scopes = scopes
    self.token = token
    self.tokenHint = tokenHint
    self.pairedAt = pairedAt
  }
}

public protocol MobileRemoteDaemonPairingTransport: Sendable {
  func claim(
    invitation: MobileRemoteDaemonPairingInvitation,
    clientID: String,
    displayName: String,
    platform: String
  ) async throws -> MobileRemoteDaemonPairingClaim
}

public enum MobileRemoteDaemonPairingError: Error, Equatable, Sendable {
  case invalidResponse
  case serverStatus(Int)
  case claimMismatch
}

public struct MobileRemoteDaemonPairingDevice: Equatable, Sendable {
  public static let iOS = Self(identityID: "default-mobile-device", platform: "ios")
  public static let watchOS = Self(identityID: "default-watch-device", platform: "watchos")

  public let identityID: String
  public let platform: String

  public init(identityID: String, platform: String) {
    self.identityID = identityID
    self.platform = platform
  }

  public func owns(_ credential: MobilePairedStationCredential) -> Bool {
    credential.deviceIdentityID == identityID
      && credential.remoteDaemonAccess?.platform.caseInsensitiveCompare(platform) == .orderedSame
  }
}

public struct URLSessionMobileRemoteDaemonPairingTransport:
  MobileRemoteDaemonPairingTransport, Sendable
{
  public typealias SessionFactory = @Sendable (MobileRemoteDaemonSPKIPin) -> URLSession

  private let sessionFactory: SessionFactory

  public init() {
    self.init(sessionFactory: Self.defaultSession)
  }

  public init(sessionFactory: @escaping SessionFactory) {
    self.sessionFactory = sessionFactory
  }

  public func claim(
    invitation: MobileRemoteDaemonPairingInvitation,
    clientID: String,
    displayName: String,
    platform: String
  ) async throws -> MobileRemoteDaemonPairingClaim {
    let url = invitation.endpoint.appending(path: "/v1/remote/pair/claim")
    let body = MobileRemoteDaemonPairingClaimRequest(
      code: invitation.code,
      domain: invitation.endpoint.host ?? "",
      clientID: clientID,
      displayName: displayName,
      platform: platform
    )
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = try JSONEncoder().encode(body)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let session = sessionFactory(invitation.serverSPKISHA256)
    defer { session.finishTasksAndInvalidate() }
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw MobileRemoteDaemonPairingError.invalidResponse
    }
    guard (200..<300).contains(response.statusCode) else {
      throw MobileRemoteDaemonPairingError.serverStatus(response.statusCode)
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let wire = try decoder.decode(MobileRemoteDaemonPairingClaimResponse.self, from: data)
    guard wire.clientID == clientID,
      wire.displayName == displayName,
      wire.platform == platform,
      !wire.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw MobileRemoteDaemonPairingError.claimMismatch
    }
    return wire.claim
  }

  private static func defaultSession(pin: MobileRemoteDaemonSPKIPin) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.waitsForConnectivity = true
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 30
    return MobileRemoteDaemonURLSessionFactory.make(configuration: configuration, pin: pin)
  }
}

public actor MobileRemoteDaemonPairingCoordinator<Transport: MobileRemoteDaemonPairingTransport> {
  private let identityStore: any MobileDeviceIdentityStore
  private let credentialStore: any MobilePairedStationCredentialStore
  private let transport: Transport
  private let device: MobileRemoteDaemonPairingDevice

  public init(
    identityStore: any MobileDeviceIdentityStore,
    credentialStore: any MobilePairedStationCredentialStore,
    transport: Transport,
    device: MobileRemoteDaemonPairingDevice
  ) {
    self.identityStore = identityStore
    self.credentialStore = credentialStore
    self.transport = transport
    self.device = device
  }

  public func pair(
    invitationURL: URL,
    deviceName: String,
    now: Date = .now
  ) async throws -> MobilePairedStationCredential {
    let invitation = try MobileRemoteDaemonPairingInvitation.decode(invitationURL, now: now)
    let identity = try await loadOrCreateIdentity(deviceName: deviceName, now: now)
    let clientID = try makeClientID(identity: identity)
    let claim = try await transport.claim(
      invitation: invitation,
      clientID: clientID,
      displayName: deviceName,
      platform: device.platform
    )
    let access = MobileRemoteDaemonAccess(
      endpoint: invitation.endpoint,
      clientID: claim.clientID,
      displayName: claim.displayName,
      platform: claim.platform,
      role: claim.role,
      scopes: claim.scopes,
      bearerToken: claim.token,
      tokenHint: claim.tokenHint,
      serverSPKISHA256: invitation.serverSPKISHA256,
      pairedAt: claim.pairedAt
    )
    let stationID = MobileRemoteDaemonStationID.make(endpoint: invitation.endpoint)
    let existing = try await credentialStore.loadAll()
    let existingCredential = existing.first { $0.stationID == stationID }
    let credential = MobilePairedStationCredential(
      stationID: stationID,
      stationName: invitation.endpoint.host ?? invitation.endpoint.absoluteString,
      endpoint: invitation.endpoint,
      stationPublicKeyFingerprint: invitation.serverSPKISHA256.value,
      deviceIdentityID: identity.id,
      snapshotKeyID: "",
      commandKeyID: "",
      symmetricKeyRawRepresentation: Data(),
      pairedAt: claim.pairedAt,
      lastUsedAt: now,
      defaultStation: existingCredential?.defaultStation ?? existing.isEmpty,
      remoteDaemonAccess: access
    )
    try await credentialStore.save(credential)
    try await removeReplacedIdentityIfUnused(
      existingCredential: existingCredential,
      existingCredentials: existing,
      replacement: credential
    )
    return credential
  }

  private func removeReplacedIdentityIfUnused(
    existingCredential: MobilePairedStationCredential?,
    existingCredentials: [MobilePairedStationCredential],
    replacement: MobilePairedStationCredential
  ) async throws {
    guard let existingCredential,
      existingCredential.deviceIdentityID != replacement.deviceIdentityID,
      !existingCredentials.contains(where: {
        $0.stationID != replacement.stationID
          && $0.deviceIdentityID == existingCredential.deviceIdentityID
      })
    else {
      return
    }
    try await identityStore.delete(id: existingCredential.deviceIdentityID)
  }

  private func loadOrCreateIdentity(
    deviceName: String,
    now: Date
  ) async throws -> MobileDeviceIdentity {
    if let identity = try await identityStore.load(id: device.identityID) {
      return identity
    }
    let identity = MobileDeviceIdentity(
      id: device.identityID,
      displayName: deviceName,
      createdAt: now
    )
    try await identityStore.save(identity)
    return identity
  }

  private func makeClientID(identity: MobileDeviceIdentity) throws -> String {
    let fingerprint = try identity.signingKeyFingerprint()
    let suffix = fingerprint.filter(\.isHexDigit).lowercased().prefix(24)
    let normalizedPlatform = device.platform.lowercased().filter { $0.isLetter || $0.isNumber }
    return "\(normalizedPlatform)-\(suffix)"
  }
}

private struct MobileRemoteDaemonPairingClaimRequest: Encodable {
  var code: String
  var domain: String
  var clientID: String
  var displayName: String
  var platform: String

  enum CodingKeys: String, CodingKey {
    case code
    case domain
    case clientID = "client_id"
    case displayName = "display_name"
    case platform
  }
}

private struct MobileRemoteDaemonPairingClaimResponse: Decodable {
  var clientID: String
  var displayName: String
  var platform: String
  var role: MobileRemoteDaemonRole
  var scopes: [String]
  var token: String
  var tokenHint: String
  var pairedAt: Date

  var claim: MobileRemoteDaemonPairingClaim {
    MobileRemoteDaemonPairingClaim(
      clientID: clientID,
      displayName: displayName,
      platform: platform,
      role: role,
      scopes: scopes,
      token: token,
      tokenHint: tokenHint,
      pairedAt: pairedAt
    )
  }

  enum CodingKeys: String, CodingKey {
    case clientID = "client_id"
    case displayName = "display_name"
    case platform
    case role
    case scopes
    case token
    case tokenHint = "token_hint"
    case pairedAt = "paired_at"
  }
}
