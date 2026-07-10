import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto
import HarnessMonitorMirrorStore

actor LiveMobileMonitorCredentialPairer: MobileMonitorCredentialPairer {
  private let relayCoordinator: MobilePairingCoordinator<URLSessionMobilePairingTransport>
  private let remoteCoordinator:
    MobileRemoteDaemonPairingCoordinator<URLSessionMobileRemoteDaemonPairingTransport>

  init(
    identityStore: any MobileDeviceIdentityStore,
    credentialStore: any MobilePairedStationCredentialStore
  ) {
    relayCoordinator = MobilePairingCoordinator(
      identityStore: identityStore,
      credentialStore: credentialStore,
      transport: URLSessionMobilePairingTransport()
    )
    remoteCoordinator = MobileRemoteDaemonPairingCoordinator(
      identityStore: identityStore,
      credentialStore: credentialStore,
      transport: URLSessionMobileRemoteDaemonPairingTransport(),
      platform: "ios"
    )
  }

  func pair(
    invitationURL: URL,
    deviceName: String,
    now: Date
  ) async throws -> MobilePairedStationCredential {
    switch try MobilePairingLink.decode(invitationURL, now: now) {
    case .relay:
      return try await relayCoordinator.pair(
        invitationURL: invitationURL,
        deviceName: deviceName,
        now: now
      )
    case .remote:
      return try await remoteCoordinator.pair(
        invitationURL: invitationURL,
        deviceName: deviceName,
        now: now
      )
    }
  }
}
