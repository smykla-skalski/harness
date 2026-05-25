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
    try encodedData(maximumBytes: nil)
  }

  public func encodedData(maximumBytes: Int?) throws -> Data {
    let data = try Self.encode(self)
    guard let maximumBytes, data.count > maximumBytes, snapshot != nil else {
      return data
    }
    var fallback = self
    fallback.snapshot = nil
    return try Self.encode(fallback)
  }

  private static func encode(_ transfer: Self) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(transfer)
  }

  public static func decode(_ data: Data) throws -> Self {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Self.self, from: data)
  }

  public func replacementPlan(
    replacing currentCredentials: [MobilePairedStationCredential]
  ) -> MobileWatchPairingReplacementPlan {
    guard !credentials.isEmpty else {
      return MobileWatchPairingReplacementPlan(
        credentialStationIDsToDelete: [],
        identityIDsToDelete: []
      )
    }
    let incomingStationIDs = Set(credentials.map(\.stationID))
    let incomingIdentityIDs = Set(credentials.map(\.deviceIdentityID))
    let incomingIdentityIDByStation = credentials.reduce(into: [String: String]()) {
      identityIDs, credential in
      identityIDs[credential.stationID] = credential.deviceIdentityID
    }
    let staleCredentials = currentCredentials.filter {
      !incomingStationIDs.contains($0.stationID)
    }
    let staleIdentityIDs = currentCredentials.compactMap { credential -> String? in
      guard !incomingIdentityIDs.contains(credential.deviceIdentityID) else {
        return nil
      }
      guard incomingIdentityIDByStation[credential.stationID] != credential.deviceIdentityID else {
        return nil
      }
      return credential.deviceIdentityID
    }
    return MobileWatchPairingReplacementPlan(
      credentialStationIDsToDelete: staleCredentials.map(\.stationID).sorted(),
      identityIDsToDelete: Set(staleIdentityIDs).sorted()
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

extension MobileMirrorSnapshot {
  @discardableResult
  public mutating func ensurePairedStationPlaceholders(
    for credentials: [MobilePairedStationCredential],
    defaultStationID: String?,
    now: Date = .now
  ) -> Bool {
    guard !credentials.isEmpty else {
      return false
    }
    var stations = stations
    var changed = false
    for credential in credentials where !stations.contains(where: { $0.id == credential.stationID })
    {
      stations.append(
        MobileStationSummary(
          id: credential.stationID,
          displayName: credential.stationName,
          state: .stale,
          lastSeenAt: now,
          activeSessionCount: 0,
          needsYouCount: 0,
          commandQueueCount: 0,
          defaultStation: credential.stationID == defaultStationID
        )
      )
      changed = true
    }
    let normalizedStations = stations.map { station in
      var station = station
      station.defaultStation = station.id == defaultStationID
      return station
    }
    if normalizedStations != self.stations {
      self.stations = normalizedStations
      changed = true
    }
    return changed
  }
}
