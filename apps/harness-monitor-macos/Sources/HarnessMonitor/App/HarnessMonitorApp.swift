import HarnessMonitorKit
import HarnessMonitorRegistry
import HarnessMonitorUIPreviewable
import SwiftData
import SwiftUI

@main
@MainActor
struct HarnessMonitorApp: App {
  @NSApplicationDelegateAdaptor private var delegate: HarnessMonitorAppDelegate
  private let container: ModelContainer?
  private let isUITesting: Bool
  private let launchMode: HarnessMonitorLaunchMode
  private let mainWindowDefaultSize: CGSize
  private let notificationController: HarnessMonitorUserNotificationController
  private let perfScenario: HarnessMonitorPerfScenario?
  @State private var store: HarnessMonitorStore
  @State private var agentTuiNavigationBridge: AgentTuiWindowNavigationBridge
  @State private var windowCommandRouting: WindowCommandRoutingState
  @State private var preferencesSelectedSection: PreferencesSection
  @AppStorage(HarnessMonitorThemeDefaults.modeKey)
  private var themeMode: HarnessMonitorThemeMode = .auto
  @AppStorage(HarnessMonitorTextSize.storageKey)
  private var textSizeIndex = HarnessMonitorTextSize.defaultIndex

  init() {
    UserDefaults.standard.register(defaults: [
      "NSUseAnimatedFocusRing": false
    ])

    let configuration = HarnessMonitorAppConfiguration.resolve()
    HarnessMonitorTelemetry.shared.bootstrap(using: configuration.environment)
    container = configuration.container
    isUITesting = configuration.isUITesting
    launchMode = configuration.launchMode
    mainWindowDefaultSize = configuration.mainWindowDefaultSize
    let notificationController = HarnessMonitorUserNotificationController()
    notificationController.activate()
    self.notificationController = notificationController
    perfScenario = configuration.perfScenario
    _store = State(initialValue: configuration.store)
    _agentTuiNavigationBridge = State(initialValue: AgentTuiWindowNavigationBridge())
    _windowCommandRouting = State(initialValue: WindowCommandRoutingState())
    _preferencesSelectedSection = State(initialValue: configuration.preferencesInitialSection)
  }

  var body: some Scene {
    WindowGroup("Harness Monitor") {
      mainWindowContent
        .trackWindow(registry: HarnessMonitorMCPAccessibilityService.shared.registry)
    }
    .windowToolbarStyle(.unified)
    .defaultSize(width: mainWindowDefaultSize.width, height: mainWindowDefaultSize.height)
    .restorationBehavior(allowsWindowRestoration ? .automatic : .disabled)
    .commands {
      HarnessMonitorAppCommands(
        store: store,
        agentTuiNavigationBridge: agentTuiNavigationBridge,
        windowCommandRouting: windowCommandRouting,
        displayState: store.commandsDisplayState,
        textSizeIndex: textSizeIndex,
        increaseTextSize: increaseTextSize,
        decreaseTextSize: decreaseTextSize,
        resetTextSize: resetTextSize,
        refreshStore: refreshStore,
        focusSidebarSearch: focusSidebarSearch,
        startDaemon: startDaemon,
        installLaunchAgent: installLaunchAgent,
        observeSelectedSession: observeSelectedSession,
        endSelectedSession: endSelectedSession,
        inspectSessionOverview: inspectSessionOverview,
        inspectObserver: inspectObserver
      )
    }

    Window("Preferences", id: HarnessMonitorWindowID.preferences) {
      HarnessMonitorSettingsRootView(
        store: store,
        notifications: notificationController,
        windowCommandRouting: windowCommandRouting,
        themeMode: $themeMode,
        selectedSection: $preferencesSelectedSection
      )
      .trackWindow(registry: HarnessMonitorMCPAccessibilityService.shared.registry)
    }
    .windowStyle(.titleBar)
    .defaultSize(width: 860, height: 620)
    .restorationBehavior(allowsWindowRestoration ? .automatic : .disabled)

    Window("Agents", id: HarnessMonitorWindowID.agents) {
      AgentTuiWindowRootView(
        store: store,
        navigationBridge: agentTuiNavigationBridge,
        windowCommandRouting: windowCommandRouting,
        themeMode: $themeMode
      )
      .trackWindow(registry: HarnessMonitorMCPAccessibilityService.shared.registry)
    }
    .windowStyle(.titleBar)
    .defaultSize(width: 980, height: 620)
    .restorationBehavior(allowsWindowRestoration ? .automatic : .disabled)
  }

  private var allowsWindowRestoration: Bool {
    launchMode == .live && !isUITesting
  }

  @ViewBuilder private var mainWindowContent: some View {
    if let container {
      HarnessMonitorWindowRootView(
        delegate: delegate,
        store: store,
        notifications: notificationController,
        windowCommandRouting: windowCommandRouting,
        themeMode: $themeMode,
        preferencesSelectedSection: $preferencesSelectedSection,
        perfScenario: perfScenario
      )
      .modelContainer(container)
      .mcpAccessibilityServiceGate()
    } else {
      HarnessMonitorWindowRootView(
        delegate: delegate,
        store: store,
        notifications: notificationController,
        windowCommandRouting: windowCommandRouting,
        themeMode: $themeMode,
        preferencesSelectedSection: $preferencesSelectedSection,
        perfScenario: perfScenario
      )
      .mcpAccessibilityServiceGate()
    }
  }

  private func increaseTextSize() {
    guard HarnessMonitorTextSize.canIncrease(textSizeIndex) else {
      return
    }
    textSizeIndex += 1
  }

  private func decreaseTextSize() {
    guard HarnessMonitorTextSize.canDecrease(textSizeIndex) else {
      return
    }
    textSizeIndex -= 1
  }

  private func resetTextSize() {
    textSizeIndex = HarnessMonitorTextSize.defaultIndex
  }

  private func refreshStore() {
    Task {
      await store.refresh()
    }
  }

  private func focusSidebarSearch() {
    store.focusSidebarSearch()
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
