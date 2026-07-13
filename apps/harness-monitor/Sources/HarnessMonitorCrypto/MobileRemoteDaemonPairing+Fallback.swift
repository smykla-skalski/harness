import Foundation

func updatedRemotePairingCredential(
  _ credential: MobilePairedStationCredential,
  access: MobileRemoteDaemonAccess,
  now: Date
) -> MobilePairedStationCredential {
  var credential = credential
  credential.remoteDaemonAccess = access
  credential.lastUsedAt = now
  return credential
}

func newRemotePairingCredential(
  invitation: MobileRemoteDaemonPairingInvitation,
  identity: MobileDeviceIdentity,
  access: MobileRemoteDaemonAccess,
  existingCredentials: [MobilePairedStationCredential],
  now: Date
) -> MobilePairedStationCredential {
  let stationID = MobileRemoteDaemonStationID.make(endpoint: invitation.endpoint)
  let existing = existingCredentials.first { $0.stationID == stationID }
  return MobilePairedStationCredential(
    stationID: stationID,
    stationName: invitation.endpoint.host ?? invitation.endpoint.absoluteString,
    endpoint: invitation.endpoint,
    stationPublicKeyFingerprint: invitation.serverSPKISHA256.value,
    deviceIdentityID: identity.id,
    snapshotKeyID: "",
    commandKeyID: "",
    symmetricKeyRawRepresentation: Data(),
    pairedAt: access.pairedAt,
    lastUsedAt: now,
    defaultStation: existing?.defaultStation ?? existingCredentials.isEmpty,
    remoteDaemonAccess: access
  )
}

func remotePairingBaseCredential(
  invitation: MobileRemoteDaemonPairingInvitation,
  identity: MobileDeviceIdentity,
  cloudFallbackStationID: String?,
  existingCredentials: [MobilePairedStationCredential]
) throws -> MobilePairedStationCredential? {
  if let cloudFallbackStationID {
    guard
      let selected = existingCredentials.first(where: {
        $0.stationID == cloudFallbackStationID
      }),
      isCompatibleCloudFallback(
        selected,
        invitation: invitation,
        identity: identity
      )
    else {
      throw MobileRemoteDaemonPairingError.invalidCloudFallbackStation
    }
    return selected
  }

  if let existingRemote = existingCredentials.first(where: {
    $0.remoteDaemonAccess?.endpoint == invitation.endpoint
  }), existingRemote.hasCloudMirrorAccess || remoteIdentityID(existingRemote) == identity.id {
    return existingRemote
  }

  let cloudFallbacks = existingCredentials.filter { credential in
    isCompatibleCloudFallback(
      credential,
      invitation: invitation,
      identity: identity
    )
  }
  guard cloudFallbacks.count == 1 else {
    return nil
  }
  return cloudFallbacks[0]
}

private func isCompatibleCloudFallback(
  _ credential: MobilePairedStationCredential,
  invitation: MobileRemoteDaemonPairingInvitation,
  identity: MobileDeviceIdentity
) -> Bool {
  credential.hasCloudMirrorAccess
    && (credential.remoteDaemonAccess == nil
      || credential.remoteDaemonAccess?.endpoint == invitation.endpoint)
    && (credential.deviceIdentityID == identity.id
      || identity.id == MobileRemoteDaemonPairingDevice.watchOS.identityID)
}

private func remoteIdentityID(_ credential: MobilePairedStationCredential) -> String {
  credential.remoteDaemonAccess?.deviceIdentityID ?? credential.deviceIdentityID
}
