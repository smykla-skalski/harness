import Foundation

extension MobileWatchPairingTransfer {
  public func preservingLocallyPairedRemoteCredentials(
    for device: MobileRemoteDaemonPairingDevice,
    currentIdentities: [MobileDeviceIdentity],
    currentCredentials: [MobilePairedStationCredential]
  ) -> Self {
    let localCredentials = currentCredentials.filter(device.owns)
    guard !localCredentials.isEmpty else {
      return self
    }

    let localStationIDs = Set(localCredentials.map(\.stationID))
    let localIdentityIDs = Set(localCredentials.map(\.deviceIdentityID))
    var mergedCredentials = credentials.filter { !localStationIDs.contains($0.stationID) }
    if localCredentials.contains(where: \.defaultStation) {
      for index in mergedCredentials.indices {
        mergedCredentials[index].defaultStation = false
      }
    }
    mergedCredentials.append(contentsOf: localCredentials)
    mergedCredentials.sort { $0.stationID < $1.stationID }

    let referencedIdentityIDs = Set(mergedCredentials.map(\.deviceIdentityID))
    var identitiesByID: [String: MobileDeviceIdentity] = [:]
    for identity in identities where referencedIdentityIDs.contains(identity.id) {
      identitiesByID[identity.id] = identity
    }
    for identity in currentIdentities where localIdentityIDs.contains(identity.id) {
      identitiesByID[identity.id] = identity
    }

    var reconciled = self
    reconciled.credentials = mergedCredentials
    reconciled.identities = identitiesByID.values.sorted { $0.id < $1.id }
    return reconciled
  }
}
