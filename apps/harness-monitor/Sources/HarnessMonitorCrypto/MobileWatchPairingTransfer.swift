import Foundation

public struct MobileWatchPairingTransfer: Codable, Equatable, Sendable {
  public var identities: [MobileDeviceIdentity]
  public var credentials: [MobilePairedStationCredential]
  public var exportedAt: Date

  public init(
    identities: [MobileDeviceIdentity],
    credentials: [MobilePairedStationCredential],
    exportedAt: Date = .now
  ) {
    self.identities = identities
    self.credentials = credentials
    self.exportedAt = exportedAt
  }

  public func encodedData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(self)
  }

  public static func decode(_ data: Data) throws -> MobileWatchPairingTransfer {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Self.self, from: data)
  }
}
