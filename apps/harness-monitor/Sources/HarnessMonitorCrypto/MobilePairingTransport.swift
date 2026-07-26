import CryptoKit
import Foundation
import HarnessMonitorCore

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
      throw MobilePairingError.serverStatus(httpResponse.statusCode)
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
