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
    let incomingIdentityIDByStation = Dictionary(
      uniqueKeysWithValues: credentials.map { ($0.stationID, $0.deviceIdentityID) }
    )
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

  /// Whether applying this transfer would change the watch's stored pairing material
  /// (identities or credentials) versus what it already holds. The iPhone re-sends the same
  /// pairing data with every mirror snapshot it relays, so a watch that reloads on every
  /// payload restarts its sync loop continuously and never settles past "Syncing". Compare
  /// order-independently and reload only when this returns true.
  public func changesPairingMaterial(
    currentIdentities: [MobileDeviceIdentity],
    currentCredentials: [MobilePairedStationCredential]
  ) -> Bool {
    let incomingCredentials = credentials.sorted { $0.stationID < $1.stationID }
    let knownCredentials = currentCredentials.sorted { $0.stationID < $1.stationID }
    guard incomingCredentials == knownCredentials else {
      return true
    }
    let incomingIdentities = identities.sorted { $0.id < $1.id }
    let knownIdentities = currentIdentities.sorted { $0.id < $1.id }
    return incomingIdentities != knownIdentities
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
