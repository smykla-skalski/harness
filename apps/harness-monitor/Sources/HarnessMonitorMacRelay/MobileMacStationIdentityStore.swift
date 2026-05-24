import Foundation
import HarnessMonitorCrypto

public struct MobileMacStationIdentityStore: Sendable {
  private let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func loadOrCreate(stationName: String, now: Date = .now) throws
    -> MobilePairingStationIdentity
  {
    if FileManager.default.fileExists(atPath: fileURL.path) {
      let data = try Data(contentsOf: fileURL)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      var identity = try decoder.decode(MobilePairingStationIdentity.self, from: data)
      if identity.stationName != stationName {
        identity.stationName = stationName
        try save(identity)
      }
      return identity
    }

    let identity = MobilePairingStationIdentity(
      stationID: "station-\(UUID().uuidString.lowercased())",
      stationName: stationName,
      createdAt: now
    )
    try save(identity)
    return identity
  }

  public func save(_ identity: MobilePairingStationIdentity) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(identity)
    try data.write(to: fileURL, options: [.atomic])
  }
}
