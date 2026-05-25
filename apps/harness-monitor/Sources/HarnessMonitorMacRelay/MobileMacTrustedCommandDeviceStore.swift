import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCrypto

public actor MobileMacTrustedCommandDeviceStore: MobileCommandTrustStore,
  MobilePairingTrustedDeviceStore
{
  private let fileURL: URL?
  private var devicesByKey: [String: MobilePairingTrustedDevice]

  public init(devices: [MobilePairingTrustedDevice] = [], fileURL: URL? = nil) throws {
    self.fileURL = fileURL
    if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
      let data = try Data(contentsOf: fileURL)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let storedDevices = try decoder.decode([MobilePairingTrustedDevice].self, from: data)
      devicesByKey = Dictionary(
        uniqueKeysWithValues: storedDevices.map { (Self.key(for: $0), $0) }
      )
      for device in devices {
        devicesByKey[Self.key(for: device)] = device
      }
    } else {
      devicesByKey = Dictionary(uniqueKeysWithValues: devices.map { (Self.key(for: $0), $0) })
    }
  }

  public func trust(_ device: MobilePairingTrustedDevice) async throws {
    devicesByKey[Self.key(for: device)] = device
    try persist()
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

  public func publicSigningKey(
    actorDeviceID: String,
    signingKeyFingerprint: String
  ) async throws -> Data? {
    devicesByKey[Self.key(deviceID: actorDeviceID, fingerprint: signingKeyFingerprint)]?
      .signingPublicKeyRawRepresentation
  }

  private func persist() throws {
    guard let fileURL else {
      return
    }
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(sortedTrustedDevices())
    try data.write(to: fileURL, options: [.atomic])
  }

  private func sortedTrustedDevices() -> [MobilePairingTrustedDevice] {
    devicesByKey.values.sorted {
      if $0.pairedAt != $1.pairedAt {
        return $0.pairedAt < $1.pairedAt
      }
      return $0.deviceID < $1.deviceID
    }
  }

  nonisolated private static func key(for device: MobilePairingTrustedDevice) -> String {
    key(deviceID: device.deviceID, fingerprint: device.signingKeyFingerprint)
  }

  nonisolated private static func key(deviceID: String, fingerprint: String) -> String {
    "\(deviceID)|\(fingerprint)"
  }
}
