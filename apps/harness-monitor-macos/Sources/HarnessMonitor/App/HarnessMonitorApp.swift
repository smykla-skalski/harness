import HarnessMonitorKit
import Observation
import SwiftUI

@main
struct HarnessMonitorApp: App {
  @State private var store = MonitorStore(daemonController: DaemonController())

  var body: some Scene {
    WindowGroup {
      ContentView(store: store)
        .task {
          await store.bootstrapIfNeeded()
        }
    }
    .windowStyle(.titleBar)
    .defaultSize(width: 1640, height: 980)
    .commands {
      SidebarCommands()
    }
  }
}
