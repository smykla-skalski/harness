import SwiftUI

@main
struct HarnessMonitorMobileApp: App {
  @State private var store = MobileMonitorStore()

  var body: some Scene {
    WindowGroup {
      MobileRootView()
        .environment(store)
    }
  }
}
