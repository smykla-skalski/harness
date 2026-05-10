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
  // App-internal access; helpers in HarnessMonitorApp+Helpers.swift use it.
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
  // App-internal access; text-size helpers live in HarnessMonitorApp+Helpers.swift.
  @AppStorage(HarnessMonitorTextSize.storageKey)
  var textSizeIndex = HarnessMonitorTextSize.defaultIndex
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
    openRecentWindowScene
    sessionWindowScene
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
  private func sessionWindowSceneContent(
    token: Binding<SessionWindowToken?>
  ) -> some View {
    if rendersLiveSceneContent, let tokenValue = token.wrappedValue {
      SessionWindowRootView(
        token: tokenValue,
        store: store,
        notifications: notificationController,
        acpAttentionState: acpAttentionState,
        keyWindowObserver: keyWindowObserver,
        windowCommandRouting: windowCommandRouting,
        mcpWindowCommandRegistrar: mcpWindowCommandRegistrar,
        sessionWindowPresenceTracker: sessionWindowPresenceTracker,
        themeMode: $themeMode
      )
      .trackWindow(registry: HarnessMonitorMCPAccessibilityService.shared.registry)
    } else {
      Color.clear.accessibilityHidden(true)
    }
  }

  @ViewBuilder
  private var openRecentWindowSceneContent: some View {
    if rendersLiveSceneContent {
      openRecentWindowContent
        .modifier(SessionWindowTabbing(isSessionWindow: false))
        .trackWindow(registry: HarnessMonitorMCPAccessibilityService.shared.registry)
    } else {
      Color.clear.accessibilityHidden(true)
    }
  }

  private var openRecentWindowScene: some Scene {
    Window(
      "Open Recent Session",
      id: HarnessMonitorWindowID.openRecent
    ) {
      openRecentWindowSceneContent
    }
    .windowToolbarStyle(.unified)
    .defaultSize(width: mainWindowDefaultSize.width, height: mainWindowDefaultSize.height)
    .restorationBehavior(.disabled)
    .defaultLaunchBehavior(shouldHandleInitialWindowRouting ? .suppressed : .automatic)
    .onChange(of: scenePhase, initial: true) { _, _ in
      installMainWindowLauncherIfNeeded()
      scheduleInitialWindowRoutingIfNeeded()
    }
    .commands {
      mainWindowCommands
    }
  }

  private var sessionWindowScene: some Scene {
    WindowGroup(
      id: HarnessMonitorWindowID.sessionScene,
      for: SessionWindowToken.self
    ) { token in
      sessionWindowSceneContent(token: token)
    }
    .windowToolbarStyle(.unified)
    .defaultSize(width: mainWindowDefaultSize.width, height: mainWindowDefaultSize.height)
    .restorationBehavior(allowsWindowRestoration ? .automatic : .disabled)
    .defaultLaunchBehavior(shouldHandleInitialWindowRouting ? .suppressed : .automatic)
    .commandsRemoved()
  }

  @CommandsBuilder private var mainWindowCommands: some Commands {
    HarnessMonitorMainCommandSet(
      store: store,
      windowCommandRouting: windowCommandRouting,
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
      openWindow(id: HarnessMonitorWindowID.openRecent)
    }
  }

  private var shouldHandleInitialWindowRouting: Bool {
    launchMode == .live && !isTestRun
  }

  private func scheduleInitialWindowRoutingIfNeeded() {
    guard shouldHandleInitialWindowRouting else {
      return
    }
    guard !hasScheduledInitialWindowRouting else {
      return
    }
    // Live launches set `defaultLaunchBehavior(.suppressed)` on every scene,
    // so no window opens automatically and the App-level scenePhase never
    // advances past `.background`. Routing therefore fires on the first
    // scenePhase callback regardless of its value:
    // `installMainWindowLauncherIfNeeded` runs in the same closure first so
    // the launcher's `openWindow` closure is already captured, and the
    // routed Task runs on MainActor where `openWindow` is valid.
    hasScheduledInitialWindowRouting = true
    Task { @MainActor in
      await routeInitialWindows()
    }
  }

  @MainActor
  private func routeInitialWindows() async {
    let tabbingPreference = SessionWindowTabbingPreference.resolved(
      rawValue: UserDefaults.standard.string(forKey: SessionWindowTabbingPreference.storageKey)
    )
    let router = HarnessMonitorInitialWindowRouter(
      store: store,
      launchBehavior: launchBehavior,
      tabbingPreference: tabbingPreference,
      openWelcomeWindow: {
        openWindow(id: HarnessMonitorWindowID.openRecent)
      },
      openSessionWindow: { sessionID in
        openWindow.openHarnessSessionWindow(sessionID: sessionID)
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

  @ViewBuilder private var openRecentWindowContent: some View {
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
          settingsSelectedSection: $settingsSelectedSection,
          perfScenario: perfScenario,
          defersInitialContentUntilBootstrap: defersInitialMainWindowUntilBootstrap
        )
      }
    }
    .onChange(of: store.openFolderRequest) { _, _ in
      presentOpenFolder()
    }
    .attachExternalSessionImporter(store: store)
  }

}
