import CryptoKit
import Foundation
import HarnessMonitorCore

public enum MobilePairingError: Error, Equatable, Sendable {
  case unsupportedURL(String)
  case missingPayload
  case invalidPayload
  case expired(Date)
  case unsupportedEndpointScheme(String?)
  case stationMismatch(expected: String, actual: String)
  case nonceMismatch(expected: String, actual: String)
  case stationFingerprintMismatch(expected: String, actual: String)
  case invalidDeviceAgreementKey
  case invalidStationAgreementKey
}

public enum MobilePairingInvitationCodec {
  public static let urlScheme = "harness"
  public static let urlHost = "pair"

  public static func encode(_ invitation: MobilePairingInvitation) throws -> URL {
    let payload = try encodedPayload(invitation)
    var components = URLComponents()
    components.scheme = urlScheme
    components.host = urlHost
    components.queryItems = [
      URLQueryItem(name: "payload", value: payload)
    ]
    guard let url = components.url else {
      throw MobilePairingError.invalidPayload
    }
    return url
  }

  public static func decode(_ value: String, now: Date = .now) throws -> MobilePairingInvitation {
    if let url = URL(string: value), url.scheme != nil {
      return try decode(url, now: now)
    }
    if let data = Data(base64URLEncoded: value) {
      return try decodePayload(data, now: now)
    }
    guard let data = value.data(using: .utf8) else {
      throw MobilePairingError.invalidPayload
    }
    return try decodePayload(data, now: now)
  }

  public static func decode(_ url: URL, now: Date = .now) throws -> MobilePairingInvitation {
    guard url.scheme == urlScheme, url.host == urlHost else {
      throw MobilePairingError.unsupportedURL(url.absoluteString)
    }
    guard
      let payload = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first(where: { $0.name == "payload" })?
        .value,
      let data = Data(base64URLEncoded: payload)
    else {
      throw MobilePairingError.missingPayload
    }
    return try decodePayload(data, now: now)
  }

  private static func encodedPayload(_ invitation: MobilePairingInvitation) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(invitation).base64URLEncodedString()
  }

  private static func decodePayload(
    _ data: Data,
    now: Date
  ) throws -> MobilePairingInvitation {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let invitation: MobilePairingInvitation
    do {
      invitation = try decoder.decode(MobilePairingInvitation.self, from: data)
    } catch {
      throw MobilePairingError.invalidPayload
    }
    try validate(invitation, now: now)
    return invitation
  }

  private static func validate(
    _ invitation: MobilePairingInvitation,
    now: Date
  ) throws {
    guard invitation.expiresAt > now else {
      throw MobilePairingError.expired(invitation.expiresAt)
    }
    let scheme = invitation.endpoint.scheme
    guard scheme == "http" || scheme == "https" else {
      throw MobilePairingError.unsupportedEndpointScheme(scheme)
    }
    guard invitation.endpoint.host?.isEmpty == false else {
      throw MobilePairingError.unsupportedURL(invitation.endpoint.absoluteString)
    }
  }
}

public struct MobilePairingRequest: Codable, Equatable, Sendable {
  public var stationID: String
  public var nonce: String
  public var deviceID: String
  public var deviceDisplayName: String
  public var deviceSigningPublicKeyRawRepresentation: Data
  public var deviceAgreementKeyRawRepresentation: Data
  public var deviceSigningKeyFingerprint: String

  public init(
    stationID: String,
    nonce: String,
    deviceID: String,
    deviceDisplayName: String,
    deviceSigningPublicKeyRawRepresentation: Data,
    deviceAgreementKeyRawRepresentation: Data,
    deviceSigningKeyFingerprint: String
  ) {
    self.stationID = stationID
    self.nonce = nonce
    self.deviceID = deviceID
    self.deviceDisplayName = deviceDisplayName
    self.deviceSigningPublicKeyRawRepresentation = deviceSigningPublicKeyRawRepresentation
    self.deviceAgreementKeyRawRepresentation = deviceAgreementKeyRawRepresentation
    self.deviceSigningKeyFingerprint = deviceSigningKeyFingerprint
  }
}

public struct MobilePairingResponse: Codable, Equatable, Sendable {
  public var stationID: String
  public var stationName: String
  public var nonce: String
  public var stationAgreementKeyRawRepresentation: Data
  public var snapshotKeyID: String
  public var commandKeyID: String
  public var pairedAt: Date

  public init(
    stationID: String,
    stationName: String,
    nonce: String,
    stationAgreementKeyRawRepresentation: Data,
    snapshotKeyID: String,
    commandKeyID: String,
    pairedAt: Date
  ) {
    self.stationID = stationID
    self.stationName = stationName
    self.nonce = nonce
    self.stationAgreementKeyRawRepresentation = stationAgreementKeyRawRepresentation
    self.snapshotKeyID = snapshotKeyID
    self.commandKeyID = commandKeyID
    self.pairedAt = pairedAt
  }
}

public struct MobilePairedStationCredential: Codable, Equatable, Identifiable, Sendable {
  public var id: String { stationID }

  public var stationID: String
  public var stationName: String
  public var endpoint: URL
  public var stationPublicKeyFingerprint: String
  public var deviceIdentityID: String
  public var snapshotKeyID: String
  public var commandKeyID: String
  public var symmetricKeyRawRepresentation: Data
  public var pairedAt: Date
  public var lastUsedAt: Date?
  public var defaultStation: Bool

  public init(
    stationID: String,
    stationName: String,
    endpoint: URL,
    stationPublicKeyFingerprint: String,
    deviceIdentityID: String,
    snapshotKeyID: String,
    commandKeyID: String,
    symmetricKeyRawRepresentation: Data,
    pairedAt: Date,
    lastUsedAt: Date? = nil,
    defaultStation: Bool = false
  ) {
    self.stationID = stationID
    self.stationName = stationName
    self.endpoint = endpoint
    self.stationPublicKeyFingerprint = stationPublicKeyFingerprint
    self.deviceIdentityID = deviceIdentityID
    self.snapshotKeyID = snapshotKeyID
    self.commandKeyID = commandKeyID
    self.symmetricKeyRawRepresentation = symmetricKeyRawRepresentation
    self.pairedAt = pairedAt
    self.lastUsedAt = lastUsedAt
    self.defaultStation = defaultStation
  }
}

public protocol MobilePairingTransport: Sendable {
  func sendPairingRequest(
    _ request: MobilePairingRequest,
    to endpoint: URL
  ) async throws -> MobilePairingResponse
}

public struct URLSessionMobilePairingTransport: MobilePairingTransport {
  private let session: URLSession

  public init() {
    session = URLSession(configuration: Self.defaultSessionConfiguration())
  }

  public init(session: URLSession) {
    self.session = session
  }

  public static func defaultSessionConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.waitsForConnectivity = true
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 60
    return configuration
  }

  public func sendPairingRequest(
    _ request: MobilePairingRequest,
    to endpoint: URL
  ) async throws -> MobilePairingResponse {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var urlRequest = URLRequest(url: endpoint)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.httpBody = try encoder.encode(request)
    let (data, response) = try await session.data(for: urlRequest)
    if let httpResponse = response as? HTTPURLResponse,
      !(200..<300).contains(httpResponse.statusCode)
    {
      throw MobilePairingError.unsupportedURL(endpoint.absoluteString)
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(MobilePairingResponse.self, from: data)
  }
}

public struct MobilePairingService<Transport: MobilePairingTransport>: Sendable {
  private let transport: Transport

  public init(transport: Transport) {
    self.transport = transport
  }

  public func pair(
    invitation: MobilePairingInvitation,
    deviceIdentity: MobileDeviceIdentity,
    now: Date = .now
  ) async throws -> MobilePairedStationCredential {
    _ = try MobilePairingInvitationCodec.decode(
      try MobilePairingInvitationCodec.encode(invitation),
      now: now
    )
    let request = try MobilePairingRequest(
      stationID: invitation.stationID,
      nonce: invitation.nonce,
      deviceID: deviceIdentity.id,
      deviceDisplayName: deviceIdentity.displayName,
      deviceSigningPublicKeyRawRepresentation:
        deviceIdentity
        .signingPublicKeyRawRepresentation(),
      deviceAgreementKeyRawRepresentation:
        deviceIdentity
        .agreementPublicKeyRawRepresentation(),
      deviceSigningKeyFingerprint: deviceIdentity.signingKeyFingerprint()
    )
    let response = try await transport.sendPairingRequest(request, to: invitation.endpoint)
    try validate(response: response, invitation: invitation)
    let symmetricKey = try deriveSymmetricKey(
      stationAgreementKeyRawRepresentation: response
        .stationAgreementKeyRawRepresentation,
      deviceIdentity: deviceIdentity,
      stationID: response.stationID,
      nonce: response.nonce,
      snapshotKeyID: response.snapshotKeyID
    )
    return MobilePairedStationCredential(
      stationID: response.stationID,
      stationName: response.stationName,
      endpoint: invitation.endpoint,
      stationPublicKeyFingerprint: invitation.publicKeyFingerprint,
      deviceIdentityID: deviceIdentity.id,
      snapshotKeyID: response.snapshotKeyID,
      commandKeyID: response.commandKeyID,
      symmetricKeyRawRepresentation: symmetricKey.withUnsafeBytes { Data($0) },
      pairedAt: response.pairedAt,
      lastUsedAt: now,
      defaultStation: true
    )
  }

  private func validate(
    response: MobilePairingResponse,
    invitation: MobilePairingInvitation
  ) throws {
    guard response.stationID == invitation.stationID else {
      throw MobilePairingError.stationMismatch(
        expected: invitation.stationID,
        actual: response.stationID
      )
    }
    guard response.nonce == invitation.nonce else {
      throw MobilePairingError.nonceMismatch(expected: invitation.nonce, actual: response.nonce)
    }
    let fingerprint = MobileCryptoFingerprint.fingerprint(
      response.stationAgreementKeyRawRepresentation
    )
    guard fingerprint == invitation.publicKeyFingerprint else {
      throw MobilePairingError.stationFingerprintMismatch(
        expected: invitation.publicKeyFingerprint,
        actual: fingerprint
      )
    }
  }

  private func deriveSymmetricKey(
    stationAgreementKeyRawRepresentation: Data,
    deviceIdentity: MobileDeviceIdentity,
    stationID: String,
    nonce: String,
    snapshotKeyID: String
  ) throws -> SymmetricKey {
    let devicePrivateKey = try Curve25519.KeyAgreement.PrivateKey(
      rawRepresentation: deviceIdentity.agreementPrivateKeyRawRepresentation
    )
    let stationPublicKey = try Curve25519.KeyAgreement.PublicKey(
      rawRepresentation: stationAgreementKeyRawRepresentation
    )
    let sharedSecret = try devicePrivateKey.sharedSecretFromKeyAgreement(with: stationPublicKey)
    return sharedSecret.hkdfDerivedSymmetricKey(
      using: SHA256.self,
      salt: Data(nonce.utf8),
      sharedInfo: Data("HarnessMonitorMobilePairing:\(stationID):\(snapshotKeyID)".utf8),
      outputByteCount: 32
    )
  }
}

public actor MobilePairingCoordinator<Transport: MobilePairingTransport> {
  public static var defaultIdentityID: String { "default-mobile-device" }

  private let identityStore: any MobileDeviceIdentityStore
  private let credentialStore: any MobilePairedStationCredentialStore
  private let pairingService: MobilePairingService<Transport>

  public init(
    identityStore: any MobileDeviceIdentityStore,
    credentialStore: any MobilePairedStationCredentialStore,
    transport: Transport
  ) {
    self.identityStore = identityStore
    self.credentialStore = credentialStore
    pairingService = MobilePairingService(transport: transport)
  }

  public func pair(
    invitationURL: URL,
    deviceName: String,
    now: Date = .now
  ) async throws -> MobilePairedStationCredential {
    let invitation = try MobilePairingInvitationCodec.decode(invitationURL, now: now)
    let identity = try await loadOrCreateIdentity(deviceName: deviceName, now: now)
    var credential = try await pairingService.pair(
      invitation: invitation,
      deviceIdentity: identity,
      now: now
    )
    let existingCredentials = try await credentialStore.loadAll()
    credential.defaultStation =
      existingCredentials.isEmpty
      || existingCredentials.allSatisfy { $0.stationID == credential.stationID }
    try await credentialStore.save(credential)
    return credential
  }

  private func loadOrCreateIdentity(
    deviceName: String,
    now: Date
  ) async throws -> MobileDeviceIdentity {
    if let existing = try await identityStore.load(id: Self.defaultIdentityID) {
      return existing
    }
    let identity = MobileDeviceIdentity(
      id: Self.defaultIdentityID,
      displayName: deviceName,
      createdAt: now
    )
    try await identityStore.save(identity)
    return identity
  }
}

extension Data {
  fileprivate func base64URLEncodedString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  fileprivate init?(base64URLEncoded value: String) {
    var base64 =
      value
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let padding = (4 - base64.count % 4) % 4
    base64.append(String(repeating: "=", count: padding))
    self.init(base64Encoded: base64)
  }
}
