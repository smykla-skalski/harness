import CryptoKit
import Foundation
import HarnessMonitorCore

public enum MobileCryptoError: Error, Equatable, Sendable {
  case invalidSignature
  case unsupportedEnvelopeAlgorithm(String)
}

public struct MobileDeviceIdentity: Codable, Equatable, Sendable {
  public var id: String
  public var displayName: String
  public var signingPrivateKeyRawRepresentation: Data
  public var agreementPrivateKeyRawRepresentation: Data
  public var createdAt: Date

  public init(
    id: String = UUID().uuidString,
    displayName: String,
    signingPrivateKeyRawRepresentation: Data = P256.Signing.PrivateKey().rawRepresentation,
    agreementPrivateKeyRawRepresentation: Data = Curve25519.KeyAgreement.PrivateKey()
      .rawRepresentation,
    createdAt: Date = .now
  ) {
    self.id = id
    self.displayName = displayName
    self.signingPrivateKeyRawRepresentation = signingPrivateKeyRawRepresentation
    self.agreementPrivateKeyRawRepresentation = agreementPrivateKeyRawRepresentation
    self.createdAt = createdAt
  }

  public func signingPublicKeyRawRepresentation() throws -> Data {
    try P256.Signing.PrivateKey(rawRepresentation: signingPrivateKeyRawRepresentation)
      .publicKey
      .rawRepresentation
  }

  public func agreementPublicKeyRawRepresentation() throws -> Data {
    try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: agreementPrivateKeyRawRepresentation)
      .publicKey
      .rawRepresentation
  }

  public func signingKeyFingerprint() throws -> String {
    try MobileCryptoFingerprint.fingerprint(signingPublicKeyRawRepresentation())
  }
}

public enum MobileCryptoFingerprint {
  public static func fingerprint(_ data: Data) -> String {
    SHA256.hash(data: data)
      .prefix(8)
      .map { String(format: "%02X", $0) }
      .joined(separator: ":")
  }
}

public enum MobileCommandSigner {
  public static func sign(
    command: MobileCommandRecord,
    identity: MobileDeviceIdentity,
    signedAt: Date = .now
  ) throws -> MobileSignedCommand {
    let privateKey = try P256.Signing.PrivateKey(
      rawRepresentation: identity.signingPrivateKeyRawRepresentation
    )
    let payload = try canonicalPayload(for: command)
    let signature = try privateKey.signature(for: payload)
    return MobileSignedCommand(
      command: command,
      signature: signature.derRepresentation,
      signingKeyFingerprint: try identity.signingKeyFingerprint(),
      signedAt: signedAt
    )
  }

  public static func verify(
    _ signedCommand: MobileSignedCommand,
    publicKeyRawRepresentation: Data
  ) throws -> Bool {
    let publicKey = try P256.Signing.PublicKey(rawRepresentation: publicKeyRawRepresentation)
    let signature = try P256.Signing.ECDSASignature(derRepresentation: signedCommand.signature)
    let payload = try canonicalPayload(for: signedCommand.command)
    return publicKey.isValidSignature(signature, for: payload)
  }

  public static func canonicalPayload(for command: MobileCommandRecord) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(command)
  }
}

public enum MobileEncryptedPayloadCodec {
  public static func seal<Value: Encodable>(
    _ value: Value,
    keyID: String,
    symmetricKey: SymmetricKey,
    additionalAuthenticatedData: Data = Data(),
    createdAt: Date = .now
  ) throws -> MobileEncryptedEnvelope {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let payload = try encoder.encode(value)
    let sealedBox = try AES.GCM.seal(
      payload,
      using: symmetricKey,
      authenticating: additionalAuthenticatedData
    )
    return MobileEncryptedEnvelope(
      keyID: keyID,
      nonce: Data(sealedBox.nonce),
      ciphertext: sealedBox.ciphertext,
      tag: sealedBox.tag,
      additionalAuthenticatedData: additionalAuthenticatedData,
      createdAt: createdAt
    )
  }

  public static func open<Value: Decodable>(
    _ envelope: MobileEncryptedEnvelope,
    as type: Value.Type = Value.self,
    symmetricKey: SymmetricKey
  ) throws -> Value {
    guard envelope.algorithm == "AES.GCM.256" else {
      throw MobileCryptoError.unsupportedEnvelopeAlgorithm(envelope.algorithm)
    }
    let sealedBox = try AES.GCM.SealedBox(
      nonce: AES.GCM.Nonce(data: envelope.nonce),
      ciphertext: envelope.ciphertext,
      tag: envelope.tag
    )
    let payload = try AES.GCM.open(
      sealedBox,
      using: symmetricKey,
      authenticating: envelope.additionalAuthenticatedData
    )
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: payload)
  }
}

public struct MobilePayloadCipher: @unchecked Sendable {
  private let symmetricKey: SymmetricKey

  public init(rawKey: Data) {
    symmetricKey = SymmetricKey(data: rawKey)
  }

  public func seal<Value: Encodable>(
    _ value: Value,
    keyID: String,
    additionalAuthenticatedData: Data = Data(),
    createdAt: Date = .now
  ) throws -> MobileEncryptedEnvelope {
    try MobileEncryptedPayloadCodec.seal(
      value,
      keyID: keyID,
      symmetricKey: symmetricKey,
      additionalAuthenticatedData: additionalAuthenticatedData,
      createdAt: createdAt
    )
  }

  public func open<Value: Decodable>(
    _ envelope: MobileEncryptedEnvelope,
    as type: Value.Type = Value.self
  ) throws -> Value {
    try MobileEncryptedPayloadCodec.open(envelope, as: type, symmetricKey: symmetricKey)
  }
}

public actor MobileReplayProtector {
  private var acceptedCommandIDs: Set<String> = []

  public init() {}

  public func accept(_ signedCommand: MobileSignedCommand, now: Date = .now) -> Bool {
    guard signedCommand.command.expiresAt > now else {
      return false
    }
    guard !acceptedCommandIDs.contains(signedCommand.command.id) else {
      return false
    }
    acceptedCommandIDs.insert(signedCommand.command.id)
    return true
  }
}
