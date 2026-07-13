import Foundation
import HarnessMonitorCrypto
import HarnessMonitorMirrorStore

actor LiveWatchRemoteDaemonCredentialPairer: MobileMonitorCredentialPairer {
  private let coordinator:
    MobileRemoteDaemonPairingCoordinator<URLSessionMobileRemoteDaemonPairingTransport>
  private let mutationGate: MobilePairingMutationGate

  init(
    identityStore: any MobileDeviceIdentityStore,
    credentialStore: any MobilePairedStationCredentialStore,
    mutationGate: MobilePairingMutationGate
  ) {
    coordinator = MobileRemoteDaemonPairingCoordinator(
      identityStore: identityStore,
      credentialStore: credentialStore,
      transport: URLSessionMobileRemoteDaemonPairingTransport(),
      device: .watchOS
    )
    self.mutationGate = mutationGate
  }

  func pair(
    invitationURL: URL,
    deviceName: String,
    cloudFallbackStationID: String?,
    now: Date
  ) async throws -> MobilePairedStationCredential {
    try await mutationGate.perform { [coordinator] in
      try await coordinator.pair(
        invitationURL: invitationURL,
        deviceName: deviceName,
        cloudFallbackStationID: cloudFallbackStationID,
        now: now
      )
    }
  }
}
