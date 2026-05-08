import AppKit
import HarnessMonitorKit
import HarnessMonitorRegistry
import HarnessMonitorUIPreviewable
import SwiftData
import SwiftUI

@main
@MainActor
struct HarnessMonitorApp: App {
  @NSApplicationDelegateAdaptor private var delegate: HarnessMonitorAppDelegate
  @Environment(\.openWindow)
  private var openWindow
  @Environment(\.scenePhase)
  private var scenePhase
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
  @State private var menuBarStatusController: HarnessMonitorMenuBarStatusController
  @State private var sessionWindowPresenceTracker: SessionWindowPresenceTracker
  @State private var windowCommandRouting: WindowCommandRoutingState
  @State private var mcpWindowCommandRegistrar: HarnessMonitorMCPWindowCommandRegistrar
  @State private var settingsSelectedSection: SettingsSection
  @State private var hasInstalledMainWindowLauncher = false
  @State private var hasScheduledInitialWindowRouting = false
  @AppStorage(HarnessMonitorThemeDefaults.modeKey)
  private var themeMode: HarnessMonitorThemeMode = .auto
  @AppStorage(HarnessMonitorTextSize.storageKey)
  private var textSizeIndex = HarnessMonitorTextSize.defaultIndex
  @AppStorage(HarnessMonitorMenuBarDefaults.stateColorVariantsEnabledKey)
  private var menuBarStateColorVariantsEnabled =
    HarnessMonitorMenuBarDefaults.stateColorVariantsEnabledDefault
  @AppStorage(HarnessMonitorLaunchBehavior.storageKey)
  private var sessionWindowLaunchModeRawValue =
    HarnessMonitorLaunchBehavior.defaultValue.rawValue

  init() {
    UserDefaults.standard.register(defaults: [
      "NSUseAnimatedFocusRing": false
    ])

    let configuration = HarnessMonitorAppConfiguration.resolve()
    let isTestRun =
      configuration.isUITesting
      || configuration.environment.isXCTestProcess
      || HarnessMonitorAppDelegate.isCurrentTestHarnessRun()
    // Preview/playground shells run an ad-hoc signed copy of the bundle from
    // /private/tmp and lack entitlements. Skip every filesystem/telemetry
    // side effect that the canvas does not need; the preview shell crashes
    // (libdispatch BUG, NSAssertion) when these touch sandboxed services.
    let runsLiveSideEffects = configuration.launchMode == .live && !isTestRun
    if runsLiveSideEffects {
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
    }
    #if HARNESS_FEATURE_OTEL
      if runsLiveSideEffects {
        HarnessMonitorTelemetry.shared.bootstrap(using: configuration.environment)
      }
    #endif
    container = configuration.container
    isUITesting = configuration.isUITesting
    self.isTestRun = isTestRun
    launchMode = configuration.launchMode
    defersInitialMainWindowUntilBootstrap =
      configuration.defersInitialMainWindowUntilBootstrap
    mainWindowDefaultSize = configuration.mainWindowDefaultSize
    // UNUserNotificationCenter.current() asserts inside the Xcode preview shell
    // (ad-hoc signed copy at /private/tmp/...) and aborts the agent before the
    // canvas ever mounts. Use the stub controller for any non-live launch.
    let notificationController =
      runsLiveSideEffects
      ? {
        let controller = HarnessMonitorUserNotificationController()
        controller.activate()
        return controller
      }()
      : HarnessMonitorUserNotificationController.preview(
        environment: configuration.environment
      )
    self.notificationController = notificationController
    let keyWindowObserver = KeyWindowObserver()
    self.keyWindowObserver = keyWindowObserver
    acpAttentionState = AcpPermissionAttentionState(
      keyWindowObserver: keyWindowObserver,
      notifications: notificationController
    )
    let menuBarStatusController = HarnessMonitorMenuBarStatusController()
    pendingDecisionsDockBadgeController = PendingDecisionsDockBadgeController()
    perfScenario = configuration.perfScenario
    let store = configuration.store
    _store = State(initialValue: store)
    _menuBarStatusController = State(initialValue: menuBarStatusController)
    _sessionWindowPresenceTracker = State(
      initialValue: SessionWindowPresenceTracker(
        store: store,
        notificationController: notificationController,
        dockBadgeController: pendingDecisionsDockBadgeController,
        menuBarStatusController: menuBarStatusController
      )
    )
    _windowCommandRouting = State(initialValue: WindowCommandRoutingState())
    _mcpWindowCommandRegistrar = State(initialValue: HarnessMonitorMCPWindowCommandRegistrar())
    _settingsSelectedSection = State(initialValue: configuration.settingsInitialSection)
    delegate.bind(store: store)
  }

  var body: some Scene {
    mainWindowScene
    settingsWindowScene
    menuBarExtraScene
  }

  // The Xcode preview shell injects the canvas view directly into an
  // NSPreviewTargetWindow; mounting the live root content from the App's
  // WindowGroups also lights up `.trackWindow`, SwiftData-backed children,
  // and notification observers, all of which dispatch main-actor work that
  // the preview agent reaps off-main and crashes with `BUG IN CLIENT OF
  // LIBDISPATCH`. The UI-test host also launches in `.preview`, but it still
  // needs the full scene tree so XCUITest can exercise the app.
  private var rendersLiveSceneContent: Bool {
    launchMode == .live || isUITesting
  }

  private var rendersMenuBarExtraContent: Bool {
    (launchMode == .live && !isTestRun) || isUITesting
  }

  private var allowsWindowRestoration: Bool {
    launchMode == .live && !isTestRun
  }

  private var launchBehavior: HarnessMonitorLaunchBehavior {
    HarnessMonitorLaunchBehavior.resolved(rawValue: sessionWindowLaunchModeRawValue)
  }

  @ViewBuilder
  private func mainWindowSceneContent(
    token: Binding<SessionWindowToken?>
  ) -> some View {
    if rendersLiveSceneContent, let tokenValue = token.wrappedValue {
      SessionWindowRootView(
        token: tokenValue,
        store: store,
        keyWindowObserver: keyWindowObserver,
        windowCommandRouting: windowCommandRouting,
        mcpWindowCommandRegistrar: mcpWindowCommandRegistrar,
        sessionWindowPresenceTracker: sessionWindowPresenceTracker,
        themeMode: $themeMode
      )
      .trackWindow(registry: HarnessMonitorMCPAccessibilityService.shared.registry)
    } else if rendersLiveSceneContent {
      mainWindowContent
        .modifier(SessionWindowTabbing(isSessionWindow: false))
        .trackWindow(registry: HarnessMonitorMCPAccessibilityService.shared.registry)
    } else {
      Color.clear.accessibilityHidden(true)
    }
  }

  private var mainWindowScene: some Scene {
    WindowGroup(
      "Open Recent Session",
      id: HarnessMonitorWindowID.main,
      for: SessionWindowToken.self
    ) { token in
      mainWindowSceneContent(token: token)
    }
    .windowToolbarStyle(.unified)
    .defaultSize(width: mainWindowDefaultSize.width, height: mainWindowDefaultSize.height)
    .restorationBehavior(allowsWindowRestoration ? .automatic : .disabled)
    .defaultLaunchBehavior(shouldHandleInitialWindowRouting ? .suppressed : .automatic)
    .onChange(of: scenePhase, initial: true) { _, newPhase in
      installMainWindowLauncherIfNeeded()
      scheduleInitialWindowRoutingIfNeeded(for: newPhase)
    }
    .commands {
      mainWindowCommands
    }
  }

  @CommandsBuilder private var mainWindowCommands: some Commands {
    HarnessMonitorMainCommandSet(
      store: store,
      textSizeIndex: textSizeIndex,
      increaseTextSize: increaseTextSize,
      decreaseTextSize: decreaseTextSize,
      resetTextSize: resetTextSize,
      refreshStore: refreshStore
    )
  }

  private func installMainWindowLauncherIfNeeded() {
    guard !hasInstalledMainWindowLauncher else {
      return
    }
    hasInstalledMainWindowLauncher = true
    HarnessMonitorMainWindowLauncher.shared.installOpenMainWindow {
      openWindow(id: HarnessMonitorWindowID.main)
    }
  }

  private var shouldHandleInitialWindowRouting: Bool {
    launchMode == .live && !isTestRun
  }

  private func scheduleInitialWindowRoutingIfNeeded(for phase: ScenePhase) {
    guard shouldHandleInitialWindowRouting else {
      return
    }
    guard phase == .active, !hasScheduledInitialWindowRouting else {
      return
    }
    hasScheduledInitialWindowRouting = true
    Task { @MainActor in
      await routeInitialWindows()
    }
  }

  @MainActor
  private func routeInitialWindows() async {
    let router = HarnessMonitorInitialWindowRouter(
      store: store,
      launchBehavior: launchBehavior,
      openWelcomeWindow: {
        openWindow(id: HarnessMonitorWindowID.main)
      },
      openSessionWindow: { sessionID in
        openWindow(
          id: HarnessMonitorWindowID.main,
          value: SessionWindowToken(sessionID: sessionID)
        )
      }
    )
    await router.route()
  }

  @ViewBuilder private var settingsSceneContent: some View {
    if rendersLiveSceneContent {
      HarnessMonitorSettingsRootView(
        store: store,
        notifications: notificationController,
        acpAttentionState: acpAttentionState,
        windowCommandRouting: windowCommandRouting,
        mcpWindowCommandRegistrar: mcpWindowCommandRegistrar,
        themeMode: $themeMode,
        selectedSection: $settingsSelectedSection
      )
      .trackWindow(registry: HarnessMonitorMCPAccessibilityService.shared.registry)
    } else {
      Color.clear.accessibilityHidden(true)
    }
  }

  private var settingsWindowScene: some Scene {
    Window("Settings", id: HarnessMonitorWindowID.settings) {
      settingsSceneContent
    }
    .windowStyle(.titleBar)
    .defaultSize(width: 860, height: 620)
    .restorationBehavior(allowsWindowRestoration ? .automatic : .disabled)
  }

  private var menuBarExtraScene: some Scene {
    // SwiftUI owns the status-item scene; keep dynamic state to asset-catalog
    // image names so the inserted MenuBarExtra stays stable.
    MenuBarExtra(
      isInserted: .constant(rendersMenuBarExtraContent)
    ) {
      HarnessMonitorMenuBarExtraContent(
        store: store,
        activeSessionWindowCount: sessionWindowPresenceTracker.activeSessionWindowCount
      )
    } label: {
      Label(HarnessMonitorMenuBarSnapshot.statusItemTitle, image: menuBarStatusItemImageName)
        .help(menuBarStatusItemHelpText)
        .accessibilityLabel(menuBarStatusItemAccessibilityLabel)
    }
    .menuBarExtraStyle(.menu)
  }

  private var menuBarStatusItemImageName: String {
    menuBarStatusController.presentation.statusItemAssetName(
      activeSessionWindowCount: sessionWindowPresenceTracker.activeSessionWindowCount,
      showsStateColorVariants: menuBarStateColorVariantsEnabled
    )
  }

  private var menuBarStatusItemHelpText: String {
    HarnessMonitorMenuBarSnapshot.statusItemHelpText(
      activeSessionWindowCount: sessionWindowPresenceTracker.activeSessionWindowCount
    )
  }

  private var menuBarStatusItemAccessibilityLabel: String {
    HarnessMonitorMenuBarSnapshot.statusItemAccessibilityLabel(
      activeSessionWindowCount: sessionWindowPresenceTracker.activeSessionWindowCount
    )
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
          settingsSelectedSection: $settingsSelectedSection,
          perfScenario: perfScenario,
          defersInitialContentUntilBootstrap: defersInitialMainWindowUntilBootstrap,
          refresh: refreshOpenRecent
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
          settingsSelectedSection: $settingsSelectedSection,
          perfScenario: perfScenario,
          defersInitialContentUntilBootstrap: defersInitialMainWindowUntilBootstrap,
          refresh: refreshOpenRecent
        )
      }
    }
    .onChange(of: store.openFolderRequest) { _, _ in
      presentOpenFolder()
    }
    .attachExternalSessionImporter(store: store)
  }

  private func handleOpenFolder(_ result: Result<[URL], any Error>) async {
    let record = await store.handleImportedFolder(result)
    HarnessMonitorLogger.swiftui.info(
      "Open folder importer handling finished: bookmarked=\((record != nil), privacy: .public)"
    )
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
      await store.manualRefresh()
    }
  }

  private func refreshOpenRecent() {
    Task {
      await store.refreshOpenRecentSessions()
    }
  }

  private func presentOpenFolder() {
    HarnessMonitorLogger.swiftui.info(
      "Presenting open folder importer: token=\(store.openFolderRequest, privacy: .public)"
    )
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "Open"
    panel.message = "Select a project folder"
    let parent = NSApp.keyWindow ?? NSApp.mainWindow
    let completion: @Sendable (NSApplication.ModalResponse) -> Void = { [store] response in
      Task { @MainActor in
        let result: Result<[URL], any Error> =
          response == .OK ? .success(panel.urls) : .success([])
        let record = await store.handleImportedFolder(result)
        HarnessMonitorLogger.swiftui.info(
          "Open folder importer handling finished: bookmarked=\((record != nil), privacy: .public)"
        )
      }
    }
    if let parent {
      panel.beginSheetModal(for: parent, completionHandler: completion)
    } else {
      panel.begin(completionHandler: completion)
    }
  }

}
