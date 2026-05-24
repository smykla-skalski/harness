import HarnessMonitorCrypto
import SwiftUI
import UIKit

@main
struct HarnessMonitorMobileApp: App {
  @State private var store: MobileMonitorStore

  init() {
    let identityStore = KeychainMobileDeviceIdentityStore()
    let credentialStore = KeychainMobilePairedStationCredentialStore()
    _store = State(
      initialValue: MobileMonitorStore(
        identityStore: identityStore,
        credentialStore: credentialStore,
        pairer: LiveMobileMonitorCredentialPairer(
          identityStore: identityStore,
          credentialStore: credentialStore
        )
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
