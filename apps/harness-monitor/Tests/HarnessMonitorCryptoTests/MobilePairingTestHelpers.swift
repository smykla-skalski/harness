import CryptoKit
import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto

func makePairingInvitation(
  now: Date,
  publicKeyFingerprint: String = "00:11:22:33:44:55:66:77",
  expiresAt: Date? = nil
) -> MobilePairingInvitation {
  MobilePairingInvitation(
    stationID: "station-mac-studio",
    stationName: "Studio",
    endpoint: URL(string: "http://studio.local:53741/pair")!,
    publicKeyFingerprint: publicKeyFingerprint,
    nonce: "pairing-nonce",
    expiresAt: expiresAt ?? now.addingTimeInterval(60)
  )
}

func makePairingIdentity(id: String, now: Date) -> MobileDeviceIdentity {
  MobileDeviceIdentity(
    id: id,
    displayName: id,
    signingPrivateKeyRawRepresentation: Data(repeating: 1, count: 32),
    agreementPrivateKeyRawRepresentation: Data(repeating: 2, count: 32),
    createdAt: now
  )
}

func makePairedStationCredential(
  stationID: String,
  deviceIdentityID: String,
  now: Date
) -> MobilePairedStationCredential {
  MobilePairedStationCredential(
    stationID: stationID,
    stationName: stationID,
    endpoint: URL(string: "https://\(stationID).local/pair")!,
    stationPublicKeyFingerprint: "00:11:22:33:44:55:66:77",
    deviceIdentityID: deviceIdentityID,
    snapshotKeyID: "snapshot-key",
    commandKeyID: "command-key",
    symmetricKeyRawRepresentation: Data(repeating: 3, count: 32),
    pairedAt: now,
    lastUsedAt: now.addingTimeInterval(10),
    defaultStation: stationID == "station-studio"
  )
}

func stationDerivedSharedKey(
  stationPrivateKey: Curve25519.KeyAgreement.PrivateKey,
  request: MobilePairingRequest,
  stationID: String,
  nonce: String,
  snapshotKeyID: String
) throws -> Data {
  let devicePublicKey = try Curve25519.KeyAgreement.PublicKey(
    rawRepresentation: request.deviceAgreementKeyRawRepresentation
  )
  let sharedSecret = try stationPrivateKey.sharedSecretFromKeyAgreement(with: devicePublicKey)
  let key = sharedSecret.hkdfDerivedSymmetricKey(
    using: SHA256.self,
    salt: Data(nonce.utf8),
    sharedInfo: Data("HarnessMonitorMobilePairing:\(stationID):\(snapshotKeyID)".utf8),
    outputByteCount: 32
  )
  return key.withUnsafeBytes { Data($0) }
}

actor FakePairingTransport: MobilePairingTransport {
  private let response: MobilePairingResponse
  private var capturedRequest: MobilePairingRequest?

  init(response: MobilePairingResponse) {
    self.response = response
  }

  func sendPairingRequest(
    _ request: MobilePairingRequest,
    to endpoint: URL
  ) async throws -> MobilePairingResponse {
    capturedRequest = request
    return response
  }

  func lastRequest() -> MobilePairingRequest? {
    capturedRequest
  }
}
