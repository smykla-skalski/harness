import HarnessKit
import SwiftData
import SwiftUI

enum HarnessWindowID {
  static let preferences = "preferences"
}

@main
@MainActor
struct HarnessApp: App {
  @NSApplicationDelegateAdaptor private var delegate: HarnessAppDelegate
  private let container: ModelContainer?
  private let isUITesting: Bool
  private let mainWindowDefaultSize: CGSize
  @State private var store: HarnessStore
  @State private var themeMode: HarnessThemeMode
  @AppStorage(HarnessTextSize.storageKey)
  private var textSizeIndex = HarnessTextSize.defaultIndex
  @FocusedValue(\.inspectorVisibility)
  private var inspectorVisibility: Binding<Bool>?

  init() {
    let configuration = HarnessAppConfiguration.resolve()
    container = configuration.container
    isUITesting = configuration.isUITesting
    mainWindowDefaultSize = configuration.mainWindowDefaultSize
    _store = State(initialValue: configuration.store)
    _themeMode = State(initialValue: configuration.initialThemeMode)
  }

  var body: some Scene {
    WindowGroup("Harness") {
      mainWindowContent
    }
    .windowToolbarStyle(.unified)
    .defaultSize(width: mainWindowDefaultSize.width, height: mainWindowDefaultSize.height)
    .restorationBehavior(isUITesting ? .disabled : .automatic)
    .commands {
      HarnessAppCommands(
        store: store,
        textSizeIndex: textSizeIndex,
        inspectorVisibility: inspectorVisibility,
        increaseTextSize: increaseTextSize,
        decreaseTextSize: decreaseTextSize,
        resetTextSize: resetTextSize,
        refreshStore: refreshStore,
        startDaemon: startDaemon,
        installLaunchAgent: installLaunchAgent,
        observeSelectedSession: observeSelectedSession,
        endSelectedSession: endSelectedSession,
        inspectSessionOverview: inspectSessionOverview,
        inspectObserver: inspectObserver
      )
    }

    Window("Preferences", id: HarnessWindowID.preferences) {
      HarnessSettingsRootView(
        store: store,
        themeMode: $themeMode
      )
    }
    .windowStyle(.titleBar)
    .defaultSize(width: 860, height: 620)
    .restorationBehavior(isUITesting ? .disabled : .automatic)
  }

  @ViewBuilder private var mainWindowContent: some View {
    if let container {
      HarnessWindowRootView(
        store: store,
        themeMode: $themeMode
      )
      .modelContainer(container)
    } else {
      HarnessWindowRootView(
        store: store,
        themeMode: $themeMode
      )
    }
  }

  private func increaseTextSize() {
    guard HarnessTextSize.canIncrease(textSizeIndex) else {
      return
    }
    textSizeIndex += 1
  }

  private func decreaseTextSize() {
    guard HarnessTextSize.canDecrease(textSizeIndex) else {
      return
    }
    textSizeIndex -= 1
  }

  private func resetTextSize() {
    textSizeIndex = HarnessTextSize.defaultIndex
  }

  private func refreshStore() {
    Task {
      await store.refresh()
    }
  }

  private func startDaemon() {
    Task {
      await store.startDaemon()
    }
  }

  private func installLaunchAgent() {
    Task {
      await store.installLaunchAgent()
    }
  }

  private func observeSelectedSession() {
    Task {
      await store.observeSelectedSession()
    }
  }

  private func endSelectedSession() {
    Task {
      await store.endSelectedSession()
    }
  }

  private func inspectSessionOverview() {
    store.inspectorSelection = .none
  }

  private func inspectObserver() {
    store.inspectObserver()
  }
}
