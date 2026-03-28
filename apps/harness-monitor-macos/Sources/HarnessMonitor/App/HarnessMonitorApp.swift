import HarnessMonitorKit
import Observation
import SwiftUI

@main
@MainActor
struct HarnessMonitorApp: App {
  @State private var store = HarnessMonitorAppStoreFactory.makeStore()

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
      CommandMenu("Harness Monitor") {
        Button("Refresh") {
          Task {
            await store.refresh()
          }
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])

        Divider()

        Button("Start Daemon") {
          Task {
            await store.startDaemon()
          }
        }

        Button("Install Launch Agent") {
          Task {
            await store.installLaunchAgent()
          }
        }

        Divider()

        Button("Observe Selected Session") {
          Task {
            await store.observeSelectedSession()
          }
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])
        .disabled(store.selectedSessionID == nil)

        Button("End Selected Session") {
          Task {
            await store.endSelectedSession()
          }
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(store.selectedSessionID == nil)
      }
    }
  }
}
