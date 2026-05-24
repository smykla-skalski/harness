import CryptoKit
import Foundation
import HarnessMonitorCore

public struct MobilePairingStationIdentity: Codable, Equatable, Identifiable, Sendable {
  public var id: String { stationID }

  public var stationID: String
  public var stationName: String
  public var agreementPrivateKeyRawRepresentation: Data
  public var snapshotKeyID: String
  public var commandKeyID: String
  public var createdAt: Date

  public init(
    stationID: String,
    stationName: String,
    agreementPrivateKeyRawRepresentation: Data = Curve25519.KeyAgreement.PrivateKey()
      .rawRepresentation,
    snapshotKeyID: String? = nil,
    commandKeyID: String? = nil,
    createdAt: Date = .now
  ) {
    self.stationID = stationID
    self.stationName = stationName
    self.agreementPrivateKeyRawRepresentation = agreementPrivateKeyRawRepresentation
    self.snapshotKeyID = snapshotKeyID ?? "snapshot-\(stationID)"
    self.commandKeyID = commandKeyID ?? "command-\(stationID)"
    self.createdAt = createdAt
  }

  public func agreementPublicKeyRawRepresentation() throws -> Data {
    try stationAgreementPrivateKey().publicKey.rawRepresentation
  }

  public func publicKeyFingerprint() throws -> String {
    try MobileCryptoFingerprint.fingerprint(agreementPublicKeyRawRepresentation())
  }

  fileprivate func stationAgreementPrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
    do {
      return try Curve25519.KeyAgreement.PrivateKey(
        rawRepresentation: agreementPrivateKeyRawRepresentation
      )
    } catch {
      throw MobilePairingError.invalidStationAgreementKey
    }
  }
}

public struct MobilePairingTrustedDevice: Codable, Equatable, Identifiable, Sendable {
  public var id: String { deviceID }

  public var stationID: String
  public var deviceID: String
  public var displayName: String
  public var signingKeyFingerprint: String
  public var signingPublicKeyRawRepresentation: Data
  public var agreementPublicKeyRawRepresentation: Data
  public var snapshotKeyID: String
  public var commandKeyID: String
  public var symmetricKeyRawRepresentation: Data
  public var pairedAt: Date
  public var lastCommandAt: Date?

  public init(
    stationID: String,
    deviceID: String,
    displayName: String,
    signingKeyFingerprint: String,
    signingPublicKeyRawRepresentation: Data,
    agreementPublicKeyRawRepresentation: Data,
    snapshotKeyID: String,
    commandKeyID: String,
    symmetricKeyRawRepresentation: Data,
    pairedAt: Date,
    lastCommandAt: Date? = nil
  ) {
    self.stationID = stationID
    self.deviceID = deviceID
    self.displayName = displayName
    self.signingKeyFingerprint = signingKeyFingerprint
    self.signingPublicKeyRawRepresentation = signingPublicKeyRawRepresentation
    self.agreementPublicKeyRawRepresentation = agreementPublicKeyRawRepresentation
    self.snapshotKeyID = snapshotKeyID
    self.commandKeyID = commandKeyID
    self.symmetricKeyRawRepresentation = symmetricKeyRawRepresentation
    self.pairedAt = pairedAt
    self.lastCommandAt = lastCommandAt
  }
}

public protocol MobilePairingTrustedDeviceStore: Sendable {
  func trust(_ device: MobilePairingTrustedDevice) async throws
  func trustedDevice(
    deviceID: String,
    signingKeyFingerprint: String
  ) async throws -> MobilePairingTrustedDevice?
  func trustedDevices() async throws -> [MobilePairingTrustedDevice]
}

public actor InMemoryMobilePairingTrustedDeviceStore: MobilePairingTrustedDeviceStore {
  private var devicesByKey: [String: MobilePairingTrustedDevice]

  public init(devices: [MobilePairingTrustedDevice] = []) {
    devicesByKey = Dictionary(uniqueKeysWithValues: devices.map { (Self.key(for: $0), $0) })
  }

  public func trust(_ device: MobilePairingTrustedDevice) async throws {
    devicesByKey[Self.key(for: device)] = device
  }

  public func trustedDevice(
    deviceID: String,
    signingKeyFingerprint: String
  ) async throws -> MobilePairingTrustedDevice? {
    devicesByKey[Self.key(deviceID: deviceID, fingerprint: signingKeyFingerprint)]
  }

  public func trustedDevices() async throws -> [MobilePairingTrustedDevice] {
    devicesByKey.values.sorted {
      if $0.pairedAt != $1.pairedAt {
        return $0.pairedAt < $1.pairedAt
      }
      return $0.deviceID < $1.deviceID
    }
  }

  private nonisolated static func key(for device: MobilePairingTrustedDevice) -> String {
    key(deviceID: device.deviceID, fingerprint: device.signingKeyFingerprint)
  }

  private nonisolated static func key(deviceID: String, fingerprint: String) -> String {
    "\(deviceID)|\(fingerprint)"
  }
}

public struct MobilePairingStationAcceptor: Sendable {
  private let identity: MobilePairingStationIdentity
  private let trustStore: any MobilePairingTrustedDeviceStore

  public init(
    identity: MobilePairingStationIdentity,
    trustStore: any MobilePairingTrustedDeviceStore
  ) {
    self.identity = identity
    self.trustStore = trustStore
  }

  public func makeInvitation(
    endpoint: URL,
    nonce: String = UUID().uuidString,
    expiresAt: Date
  ) throws -> MobilePairingInvitation {
    MobilePairingInvitation(
      stationID: identity.stationID,
      stationName: identity.stationName,
      endpoint: endpoint,
      publicKeyFingerprint: try identity.publicKeyFingerprint(),
      nonce: nonce,
      expiresAt: expiresAt
    )
  }

  public func accept(
    _ request: MobilePairingRequest,
    expectedNonce: String,
    now: Date = .now
  ) async throws -> MobilePairingResponse {
    guard request.stationID == identity.stationID else {
      throw MobilePairingError.stationMismatch(
        expected: identity.stationID,
        actual: request.stationID
      )
    }
    guard request.nonce == expectedNonce else {
      throw MobilePairingError.nonceMismatch(expected: expectedNonce, actual: request.nonce)
    }
    let symmetricKey = try deriveSymmetricKey(request: request)
    let trustedDevice = MobilePairingTrustedDevice(
      stationID: identity.stationID,
      deviceID: request.deviceID,
      displayName: request.deviceDisplayName,
      signingKeyFingerprint: request.deviceSigningKeyFingerprint,
      signingPublicKeyRawRepresentation: request.deviceSigningPublicKeyRawRepresentation,
      agreementPublicKeyRawRepresentation: request.deviceAgreementPublicKeyRawRepresentation,
      snapshotKeyID: identity.snapshotKeyID,
      commandKeyID: identity.commandKeyID,
      symmetricKeyRawRepresentation: symmetricKey.withUnsafeBytes { Data($0) },
      pairedAt: now
    )
    try await trustStore.trust(trustedDevice)
    return MobilePairingResponse(
      stationID: identity.stationID,
      stationName: identity.stationName,
      nonce: request.nonce,
      stationAgreementPublicKeyRawRepresentation:
        try identity
        .agreementPublicKeyRawRepresentation(),
      snapshotKeyID: identity.snapshotKeyID,
      commandKeyID: identity.commandKeyID,
      pairedAt: now
    )
  }

  private func deriveSymmetricKey(
    request: MobilePairingRequest
  ) throws -> SymmetricKey {
    let stationPrivateKey = try identity.stationAgreementPrivateKey()
    let devicePublicKey: Curve25519.KeyAgreement.PublicKey
    do {
      devicePublicKey = try Curve25519.KeyAgreement.PublicKey(
        rawRepresentation: request.deviceAgreementPublicKeyRawRepresentation
      )
    } catch {
      throw MobilePairingError.invalidDeviceAgreementKey
    }
    let sharedSecret = try stationPrivateKey.sharedSecretFromKeyAgreement(with: devicePublicKey)
    return sharedSecret.hkdfDerivedSymmetricKey(
      using: SHA256.self,
      salt: Data(request.nonce.utf8),
      sharedInfo: Data(
        "HarnessMonitorMobilePairing:\(identity.stationID):\(identity.snapshotKeyID)".utf8),
      outputByteCount: 32
    )
  }
}
