import Foundation
import HarnessMonitorCrypto

extension MirrorStore {
  @discardableResult
  public func pairDirectWatchDaemon(
    payload: String,
    deviceName: String,
    now: Date = .now
  ) async -> Bool {
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
      syncStatus = mobileMonitorSyncStatus(for: error)
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
          await unpair(stationID: stationID)
        }
      } catch {
        syncStatus = mobileMonitorSyncStatus(for: error)
        return
      }
    } else {
      await unpair(stationID: stationID)
    }
    guard !pairedCredentials.contains(where: { $0.stationID == stationID }) else {
      return
    }
    requestFreshPairingMaterial?()
  }
}
