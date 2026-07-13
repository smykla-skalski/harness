import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto

extension MirrorStore {
  @discardableResult
  public func pairDirectWatchDaemon(
    payload: String,
    deviceName: String,
    now: Date = .now
  ) async -> Bool {
    pairingFailureDescription = nil
    do {
      let invitationURL = try MobilePairingLink.normalizedURL(from: payload, now: now)
      guard case .remote = try MobilePairingLink.decode(invitationURL, now: now) else {
        throw MobilePairingError.unsupportedURL(invitationURL.absoluteString)
      }
      guard
        let credential = await pair(
          invitationURL: invitationURL,
          deviceName: deviceName,
          now: now
        )
      else {
        return false
      }
      return MobileRemoteDaemonPairingDevice.watchOS.owns(credential)
    } catch {
      recordPairingFailure(mobileMirrorReadableErrorDescription(error))
      return false
    }
  }

  public func removeDirectWatchPairing(stationID: String) async {
    guard let credential = pairedCredentials.first(where: { $0.stationID == stationID }),
      MobileRemoteDaemonPairingDevice.watchOS.owns(credential)
    else {
      return
    }

    if let pairingMutationGate {
      do {
        try await pairingMutationGate.perform { @MainActor [self] in
          await removeDirectWatchCredential(credential)
        }
      } catch {
        syncStatus = mobileMonitorSyncStatus(for: error)
        return
      }
    } else {
      await removeDirectWatchCredential(credential)
    }
    guard
      !pairedCredentials.contains(where: {
        $0.stationID == stationID && MobileRemoteDaemonPairingDevice.watchOS.owns($0)
      })
    else {
      return
    }
    requestFreshPairingMaterial?()
  }

  private func removeDirectWatchCredential(
    _ credential: MobilePairedStationCredential
  ) async {
    guard credential.hasCloudMirrorAccess else {
      await unpair(stationID: credential.stationID)
      return
    }
    guard let identityStore, let credentialStore else {
      syncStatus = .stale("Pairing storage is unavailable.")
      return
    }
    do {
      let remoteIdentityID = credential.remoteDaemonAccess?.deviceIdentityID
      var fallback = credential
      fallback.remoteDaemonAccess = nil
      try await credentialStore.save(fallback)
      let remainingCredentials = try await credentialStore.loadAll()
      let retainedIdentityIDs = Set(
        remainingCredentials.flatMap(\.referencedDeviceIdentityIDs)
      )
      if let remoteIdentityID, !retainedIdentityIDs.contains(remoteIdentityID) {
        try await identityStore.delete(id: remoteIdentityID)
      }
      try await rebuildSyncClients(preferredStationID: fallback.stationID)
      syncStatus = .paired(fallback.stationName)
    } catch {
      syncStatus = mobileMonitorSyncStatus(for: error)
    }
  }
}
