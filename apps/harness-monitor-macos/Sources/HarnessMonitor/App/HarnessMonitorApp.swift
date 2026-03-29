import HarnessMonitorKit
import Observation
import SwiftUI

enum MonitorThemeMode: String, CaseIterable, Identifiable {
  case auto
  case light
  case dark

  var id: String { rawValue }

  var colorScheme: ColorScheme? {
    switch self {
    case .auto: nil
    case .light: .light
    case .dark: .dark
    }
  }

  var label: String {
    switch self {
    case .auto: "Auto"
    case .light: "Light"
    case .dark: "Dark"
    }
  }
}

@main
@MainActor
struct HarnessMonitorApp: App {
  @State private var store = HarnessMonitorAppStoreFactory.makeStore()
  @AppStorage("monitorThemeMode")
  private var themeMode = MonitorThemeMode.auto

  var body: some Scene {
    Window("Harness Monitor", id: "main") {
      rootContent
    }
    .windowStyle(.titleBar)
    .windowToolbarStyle(.unified(showsTitle: true))
    .defaultLaunchBehavior(.presented)
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

    Settings {
      PreferencesView(store: store, themeMode: $themeMode)
        .frame(minWidth: 860, minHeight: 640)
    }
  }

  @ViewBuilder private var rootContent: some View {
    ContentView(store: store)
      .preferredColorScheme(themeMode.colorScheme)
      .task {
        await store.bootstrapIfNeeded()
      }
  }
}
