import CryptoKit
import Foundation
import HarnessMonitorCore

public enum MobilePairingError: Error, LocalizedError, Equatable, Sendable {
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
  case serverStatus(Int)

  public var errorDescription: String? {
    switch self {
    case .unsupportedURL:
      "This is not a recognized Harness pairing link. Check that you copied the "
        + "whole link, then try again."
    case .missingPayload:
      "The pairing link is missing its payload. Create a new pairing link and try again."
    case .invalidPayload:
      "The pairing link's payload is unreadable or ambiguous. Create a new pairing "
        + "link and try again."
    case .expired:
      "This pairing link has expired. Create a new pairing link and try again."
    case .unsupportedEndpointScheme:
      "The pairing link points to an unsupported address. Create a new pairing "
        + "link and try again."
    case .stationMismatch:
      "The station responded with a different identity than the link expected. "
        + "Create a new pairing link and try again."
    case .nonceMismatch:
      "The station's response did not match this pairing link. Create a new "
        + "pairing link and try again."
    case .stationFingerprintMismatch:
      "The station's identity did not match the pairing link. Do not continue; "
        + "create a new pairing link and try again."
    case .invalidDeviceAgreementKey:
      "This device's pairing key is invalid. Restart the app, then try again."
    case .invalidStationAgreementKey:
      "The station's pairing key is invalid. Create a new pairing link and try again."
    case .serverStatus(let statusCode):
      Self.serverStatusDescription(statusCode)
    }
  }

  private static func serverStatusDescription(_ statusCode: Int) -> String {
    switch statusCode {
    // The station's own pairing server answers 400 to everything it turns down,
    // including an invitation it has already consumed or never issued. Anything
    // else came from whatever else is listening on that address.
    case 400:
      "The station rejected this pairing request (HTTP 400). The pairing link may "
        + "already have been used. Create a new pairing link and try again."
    case 500...599:
      "The server at this address could not complete pairing (HTTP \(statusCode)). "
        + "Check that Harness Monitor is still running on the station, then try again."
    default:
      "The server at this address refused pairing (HTTP \(statusCode)). Check that "
        + "the link points at the station, then create a new pairing link and try again."
    }
  }
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
    // Match the scheme and host case-insensitively, like `MobilePairingLink`
    // and the remote decoder, so a link whose casing changed in transit (hand
    // entry, QR round-trip) still decodes. Every relay entry point — the link
    // classifier, the pairing coordinator, and the service — routes through
    // here, so the tolerance has to live at this check.
    guard url.scheme?.lowercased() == urlScheme, url.host?.lowercased() == urlHost else {
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
  public var remoteDaemonAccess: MobileRemoteDaemonAccess?

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
    defaultStation: Bool = false,
    remoteDaemonAccess: MobileRemoteDaemonAccess? = nil
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
    self.remoteDaemonAccess = remoteDaemonAccess
  }

  public var hasCloudMirrorAccess: Bool {
    !snapshotKeyID.isEmpty
      && !symmetricKeyRawRepresentation.isEmpty
  }

  public var referencedDeviceIdentityIDs: Set<String> {
    var identityIDs = Set([deviceIdentityID])
    if let remoteIdentityID = remoteDaemonAccess?.deviceIdentityID {
      identityIDs.insert(remoteIdentityID)
    }
    return identityIDs
  }
}
