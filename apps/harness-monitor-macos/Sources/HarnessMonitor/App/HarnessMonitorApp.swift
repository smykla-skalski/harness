import HarnessMonitorKit
import HarnessMonitorRegistry
import HarnessMonitorUIPreviewable
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

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
  @State private var showOpenFolder = false
  @State private var agentsNavigationBridge: AgentsWindowNavigationBridge
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
    do {
      try HarnessMonitorPaths.ensureHarnessRootNonIndexable(using: configuration.environment)
    } catch {
      HarnessMonitorLogger.store.warning(
        "Failed to mark harness root non-indexable: \(String(describing: error), privacy: .public)"
      )
    }
    do {
      try HarnessMonitorPaths.migrateLegacyGeneratedCaches(using: configuration.environment)
    } catch {
      HarnessMonitorLogger.store.warning(
        "Failed to migrate generated caches: \(String(describing: error), privacy: .public)"
      )
    }
    #if HARNESS_FEATURE_OTEL
      HarnessMonitorTelemetry.shared.bootstrap(using: configuration.environment)
    #endif
    container = configuration.container
    isUITesting = configuration.isUITesting
    launchMode = configuration.launchMode
    mainWindowDefaultSize = configuration.mainWindowDefaultSize
    let notificationController =
      configuration.isUITesting
      ? HarnessMonitorUserNotificationController.preview()
      : {
        let controller = HarnessMonitorUserNotificationController()
        controller.activate()
        return controller
      }()
    self.notificationController = notificationController
    perfScenario = configuration.perfScenario
    let store = configuration.store
    store.bindSupervisorNotifications(notificationController)
    _store = State(initialValue: store)
    _agentsNavigationBridge = State(initialValue: AgentsWindowNavigationBridge())
    _windowCommandRouting = State(initialValue: WindowCommandRoutingState())
    _preferencesSelectedSection = State(initialValue: configuration.preferencesInitialSection)
  }

  var body: some Scene {
    WindowGroup("Harness Monitor", id: HarnessMonitorWindowID.main) {
      mainWindowContent
        .trackWindow(registry: HarnessMonitorMCPAccessibilityService.shared.registry)
        .modifier(HarnessMonitorMainWindowLauncherBinder())
    }
    .windowToolbarStyle(.unified)
    .defaultSize(width: mainWindowDefaultSize.width, height: mainWindowDefaultSize.height)
    .restorationBehavior(allowsWindowRestoration ? .automatic : .disabled)
    .defaultLaunchBehavior(.presented)
    .commands {
      HarnessMonitorAppCommands(
        store: store,
        displayState: store.commandsDisplayState,
        textSizeIndex: textSizeIndex,
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
      NewSessionCommand(store: store)
      OpenFolderCommand(isPresented: $showOpenFolder)
      AttachExternalSessionCommand(store: store)
      GoCommands(
        store: store,
        agentsNavigationBridge: agentsNavigationBridge,
        windowCommandRouting: windowCommandRouting,
        displayState: store.commandsDisplayState
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
      .modifier(HarnessMonitorMainWindowLauncherBinder())
    }
    .windowStyle(.titleBar)
    .defaultSize(width: 860, height: 620)
    .restorationBehavior(allowsWindowRestoration ? .automatic : .disabled)

    Window("Agents", id: HarnessMonitorWindowID.agents) {
      AgentsWindowRootView(
        store: store,
        navigationBridge: agentsNavigationBridge,
        windowCommandRouting: windowCommandRouting,
        themeMode: $themeMode
      )
      .trackWindow(registry: HarnessMonitorMCPAccessibilityService.shared.registry)
      .modifier(HarnessMonitorMainWindowLauncherBinder())
    }
    .windowStyle(.titleBar)
    .defaultSize(width: 980, height: 620)
    .restorationBehavior(allowsWindowRestoration ? .automatic : .disabled)

    Window("Decisions", id: HarnessMonitorWindowID.decisions) {
      DecisionsWindowView(store: store)
        .trackWindow(registry: HarnessMonitorMCPAccessibilityService.shared.registry)
        .modifier(HarnessMonitorMainWindowLauncherBinder())
    }
    .windowStyle(.titleBar)
    .defaultSize(width: 900, height: 640)
    .restorationBehavior(allowsWindowRestoration ? .automatic : .disabled)
  }

  private var allowsWindowRestoration: Bool {
    launchMode == .live && !isUITesting
  }

  @ViewBuilder private var mainWindowContent: some View {
    Group {
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
    .fileImporter(
      isPresented: $showOpenFolder,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      Task { await handleOpenFolder(result) }
    }
    .onChange(of: store.openFolderRequest) { _, _ in
      showOpenFolder = true
    }
    .attachExternalSessionImporter(store: store)
  }

  private func handleOpenFolder(_ result: Result<[URL], any Error>) async {
    _ = await store.handleImportedFolder(result)
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
