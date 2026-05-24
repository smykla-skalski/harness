import Foundation
import HarnessMonitorCore

public enum MobileWatchPairingTransferEnvelope {
  public static let transferKey = "io.harnessmonitor.mobile.watch-pairing-transfer"
  public static let requestKey = "io.harnessmonitor.watch.pairing-request"
}

public struct MobileWatchPairingTransfer: Codable, Equatable, Sendable {
  public var identities: [MobileDeviceIdentity]
  public var credentials: [MobilePairedStationCredential]
  public var snapshot: MobileMirrorSnapshot?
  public var exportedAt: Date

  public init(
    identities: [MobileDeviceIdentity],
    credentials: [MobilePairedStationCredential],
    snapshot: MobileMirrorSnapshot? = nil,
    exportedAt: Date = .now
  ) {
    self.identities = identities
    self.credentials = credentials
    self.snapshot = snapshot
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

  public func replacementPlan(
    replacing currentCredentials: [MobilePairedStationCredential]
  ) -> MobileWatchPairingReplacementPlan {
    let incomingStationIDs = Set(credentials.map(\.stationID))
    let incomingIdentityIDs = Set(credentials.map(\.deviceIdentityID))
    let staleCredentials = currentCredentials.filter {
      !incomingStationIDs.contains($0.stationID)
    }
    return MobileWatchPairingReplacementPlan(
      credentialStationIDsToDelete: staleCredentials.map(\.stationID).sorted(),
      identityIDsToDelete: Set(
        staleCredentials
          .map(\.deviceIdentityID)
          .filter { !incomingIdentityIDs.contains($0) }
      )
      .sorted()
    )
  }
}

public struct MobileWatchPairingReplacementPlan: Equatable, Sendable {
  public var credentialStationIDsToDelete: [String]
  public var identityIDsToDelete: [String]

  public init(
    credentialStationIDsToDelete: [String],
    identityIDsToDelete: [String]
  ) {
    self.credentialStationIDsToDelete = credentialStationIDsToDelete
    self.identityIDsToDelete = identityIDsToDelete
  }
}
