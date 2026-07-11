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
    var mergedCredentialsByStationID: [String: MobilePairedStationCredential] = [:]
    for credential in credentials where !localStationIDs.contains(credential.stationID) {
      mergedCredentialsByStationID[credential.stationID] = credential
    }
    if localCredentials.contains(where: \.defaultStation) {
      mergedCredentialsByStationID = mergedCredentialsByStationID.mapValues { credential in
        var credential = credential
        credential.defaultStation = false
        return credential
      }
    }
    for credential in localCredentials {
      mergedCredentialsByStationID[credential.stationID] = credential
    }
    let mergedCredentials = mergedCredentialsByStationID.values.sorted {
      $0.stationID < $1.stationID
    }

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
