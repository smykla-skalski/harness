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
  private let isTestRun: Bool
  private let launchMode: HarnessMonitorLaunchMode
  private let defersInitialMainWindowUntilBootstrap: Bool
  private let mainWindowDefaultSize: CGSize
  private let notificationController: HarnessMonitorUserNotificationController
  private let keyWindowObserver: KeyWindowObserver
  private let acpAttentionState: AcpPermissionAttentionState
  private let pendingDecisionsDockBadgeController: PendingDecisionsDockBadgeController
  private let perfScenario: HarnessMonitorPerfScenario?
  @State private var store: HarnessMonitorStore
  @State private var showOpenFolder = false
  @State private var workspaceNavigationBridge: WorkspaceWindowNavigationBridge
  @State private var windowCommandRouting: WindowCommandRoutingState
  @State private var mcpWindowCommandRegistrar: HarnessMonitorMCPWindowCommandRegistrar
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
    let isTestRun =
      configuration.isUITesting
      || configuration.environment.isXCTestProcess
      || HarnessMonitorAppDelegate.isCurrentTestHarnessRun()
    if !isTestRun {
      do {
        try HarnessMonitorPaths.ensureHarnessRootNonIndexable(using: configuration.environment)
      } catch {
        HarnessMonitorLogger.store.warning(
          "Failed to mark harness root non-indexable: \(String(describing: error), privacy: .public)"
        )
      }
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
    self.isTestRun = isTestRun
    launchMode = configuration.launchMode
    defersInitialMainWindowUntilBootstrap =
      configuration.defersInitialMainWindowUntilBootstrap
    mainWindowDefaultSize = configuration.mainWindowDefaultSize
    let notificationController =
      isTestRun
      ? HarnessMonitorUserNotificationController.preview(
        environment: configuration.environment
      )
      : {
        let controller = HarnessMonitorUserNotificationController()
        controller.activate()
        return controller
      }()
    self.notificationController = notificationController
    let keyWindowObserver = KeyWindowObserver()
    self.keyWindowObserver = keyWindowObserver
    acpAttentionState = AcpPermissionAttentionState(
      keyWindowObserver: keyWindowObserver,
      notifications: notificationController
    )
    pendingDecisionsDockBadgeController = PendingDecisionsDockBadgeController()
    perfScenario = configuration.perfScenario
    let store = configuration.store
    store.bindSupervisorNotifications(notificationController)
    store.bindPendingDecisionsBadgeSync { [pendingDecisionsDockBadgeController] count in
      pendingDecisionsDockBadgeController.sync(count: count)
    }
    _store = State(initialValue: store)
    _workspaceNavigationBridge = State(initialValue: WorkspaceWindowNavigationBridge())
    _windowCommandRouting = State(initialValue: WindowCommandRoutingState())
    _mcpWindowCommandRegistrar = State(initialValue: HarnessMonitorMCPWindowCommandRegistrar())
    _preferencesSelectedSection = State(initialValue: configuration.preferencesInitialSection)
    delegate.bind(store: store)
  }

  var body: some Scene {
    mainWindowScene
    settingsWindowScene
    workspaceWindowScene
  }

  private var allowsWindowRestoration: Bool {
    launchMode == .live && !isTestRun
  }

  private var mainWindowScene: some Scene {
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
        refreshStore: refreshStore
      )
      NewSessionCommand(store: store)
      OpenFolderCommand(isPresented: $showOpenFolder)
      AttachExternalSessionCommand(store: store)
      GoCommands(
        store: store,
        workspaceNavigationBridge: workspaceNavigationBridge,
        windowCommandRouting: windowCommandRouting,
        displayState: store.commandsDisplayState
      )
      SessionCommands(
        store: store,
        displayState: store.commandsDisplayState
      )
      WindowMenuCommands()
    }
  }

  private var settingsWindowScene: some Scene {
    Window("Settings", id: HarnessMonitorWindowID.preferences) {
      HarnessMonitorSettingsRootView(
        store: store,
        notifications: notificationController,
        acpAttentionState: acpAttentionState,
        windowCommandRouting: windowCommandRouting,
        mcpWindowCommandRegistrar: mcpWindowCommandRegistrar,
        themeMode: $themeMode,
        selectedSection: $preferencesSelectedSection
      )
      .trackWindow(registry: HarnessMonitorMCPAccessibilityService.shared.registry)
      .modifier(HarnessMonitorMainWindowLauncherBinder())
    }
    .windowStyle(.titleBar)
    .defaultSize(width: 860, height: 620)
    .restorationBehavior(allowsWindowRestoration ? .automatic : .disabled)
  }

  private var workspaceWindowScene: some Scene {
    Window("Workspace", id: HarnessMonitorWindowID.workspace) {
      WorkspaceWindowRootView(
        store: store,
        notifications: notificationController,
        acpAttentionState: acpAttentionState,
        navigationBridge: workspaceNavigationBridge,
        windowCommandRouting: windowCommandRouting,
        mcpWindowCommandRegistrar: mcpWindowCommandRegistrar,
        themeMode: $themeMode
      )
      .trackWindow(registry: HarnessMonitorMCPAccessibilityService.shared.registry)
      .modifier(HarnessMonitorMainWindowLauncherBinder())
    }
    .windowStyle(.titleBar)
    .defaultSize(width: 1_140, height: 700)
    .restorationBehavior(allowsWindowRestoration ? .automatic : .disabled)
  }

  @ViewBuilder private var mainWindowContent: some View {
    Group {
      if let container {
        HarnessMonitorWindowRootView(
          delegate: delegate,
          store: store,
          notifications: notificationController,
          keyWindowObserver: keyWindowObserver,
          acpAttentionState: acpAttentionState,
          windowCommandRouting: windowCommandRouting,
          mcpWindowCommandRegistrar: mcpWindowCommandRegistrar,
          themeMode: $themeMode,
          preferencesSelectedSection: $preferencesSelectedSection,
          perfScenario: perfScenario,
          defersInitialContentUntilBootstrap: defersInitialMainWindowUntilBootstrap
        )
        .modelContainer(container)
      } else {
        HarnessMonitorWindowRootView(
          delegate: delegate,
          store: store,
          notifications: notificationController,
          keyWindowObserver: keyWindowObserver,
          acpAttentionState: acpAttentionState,
          windowCommandRouting: windowCommandRouting,
          mcpWindowCommandRegistrar: mcpWindowCommandRegistrar,
          themeMode: $themeMode,
          preferencesSelectedSection: $preferencesSelectedSection,
          perfScenario: perfScenario,
          defersInitialContentUntilBootstrap: defersInitialMainWindowUntilBootstrap
        )
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

}
