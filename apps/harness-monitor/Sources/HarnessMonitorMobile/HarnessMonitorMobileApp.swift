import HarnessMonitorCrypto
import SwiftUI
import UIKit

@main
struct HarnessMonitorMobileApp: App {
  @State private var store: MobileMonitorStore

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
          Task {
            await store.handleOpenURL(url, deviceName: UIDevice.current.name)
          }
        }
    }
  }
}
