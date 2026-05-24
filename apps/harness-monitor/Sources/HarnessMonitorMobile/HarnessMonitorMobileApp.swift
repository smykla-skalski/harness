import HarnessMonitorCrypto
import SwiftUI
import UIKit

@main
struct HarnessMonitorMobileApp: App {
  @Environment(\.scenePhase) private var scenePhase
  @State private var store: MobileMonitorStore
  @State private var pendingPairingURL: URL?

  init() {
    let identityStore = KeychainMobileDeviceIdentityStore()
    let credentialStore = KeychainMobilePairedStationCredentialStore()
    let watchPairingSyncer = MobileWatchPairingSessionBridge()
    _store = State(
      initialValue: MobileMonitorStore(
        identityStore: identityStore,
        credentialStore: credentialStore,
        pairer: LiveMobileMonitorCredentialPairer(
          identityStore: identityStore,
          credentialStore: credentialStore
        ),
        watchPairingSyncer: watchPairingSyncer
      )
    )
  }

  var body: some Scene {
    WindowGroup {
      MobileRootView()
        .environment(store)
        .onOpenURL { url in
          guard url.scheme == MobilePairingInvitationCodec.urlScheme,
            url.host == MobilePairingInvitationCodec.urlHost
          else {
            return
          }
          pendingPairingURL = url
          pairPendingInvitationIfActive()
        }
        .onChange(of: scenePhase) { _, newPhase in
          guard newPhase == .active else {
            return
          }
          pairPendingInvitationIfActive()
        }
    }
  }

  private func pairPendingInvitationIfActive() {
    guard scenePhase == .active, let url = pendingPairingURL else {
      return
    }
    pendingPairingURL = nil
    Task {
      await store.handleOpenURL(url, deviceName: UIDevice.current.name)
    }
  }
}
