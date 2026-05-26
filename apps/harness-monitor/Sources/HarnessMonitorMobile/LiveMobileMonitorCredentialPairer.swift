import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto
import HarnessMonitorMirrorStore

actor LiveMobileMonitorCredentialPairer: MobileMonitorCredentialPairer {
  private let coordinator: MobilePairingCoordinator<URLSessionMobilePairingTransport>

  init(
    identityStore: any MobileDeviceIdentityStore,
    credentialStore: any MobilePairedStationCredentialStore
  ) {
    coordinator = MobilePairingCoordinator(
      identityStore: identityStore,
      credentialStore: credentialStore,
      transport: URLSessionMobilePairingTransport()
    )
  }

  func pair(
    invitationURL: URL,
    deviceName: String,
    now: Date
  ) async throws -> MobilePairedStationCredential {
    try await coordinator.pair(invitationURL: invitationURL, deviceName: deviceName, now: now)
  }
}
