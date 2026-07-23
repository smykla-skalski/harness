import AppKit
import HarnessMonitorKit
import HarnessMonitorMacRelay
import HarnessMonitorUIPreviewable
import SwiftData
import SwiftUI

@main
@MainActor
struct HarnessMonitorApp: App {
  @NSApplicationDelegateAdaptor var delegate: HarnessMonitorAppDelegate
  @Environment(\.openWindow)
  var openWindow
  @Environment(\.scenePhase)
  var scenePhase
  let container: ModelContainer?
  let isUITesting: Bool
  let isTestRun: Bool
  let launchMode: HarnessMonitorLaunchMode
  let defersInitialMainWindowUntilBootstrap: Bool
  let mainWindowDefaultSize: CGSize
  let notificationController: HarnessMonitorUserNotificationController
  let keyWindowObserver: KeyWindowObserver
  let acpAttentionState: AcpPermissionAttentionState
  let pendingDecisionsDockBadgeController: PendingDecisionsDockBadgeController
  let perfScenario: HarnessMonitorPerfScenario?
  let initialSessionWindowRoute: SessionWindowRoute?
  let mobileRelayRuntime: MobileMacRelayRuntime?
  @State private var store: HarnessMonitorStore
  @State private var menuBarStatusController: HarnessMonitorMenuBarStatusController
  @State private var sessionWindowPresenceTracker: SessionWindowPresenceTracker
  @State private var windowCommandRouting: WindowCommandRoutingState
  @State private var windowNavigationHistory: GlobalWindowNavigationHistory
  @State private var mcpWindowCommandRegistrar: HarnessMonitorMCPWindowCommandRegistrar
  @State private var openAnythingCoordinator: OpenAnythingCorpusCoordinator
  @State private var openAnythingCorpusDriver: OpenAnythingCorpusUpdateDriver
  @State private var openAnythingLoadedSessionOverride: OpenAnythingLoadedSessionSnapshot?
  @State private var openAnythingReviews: OpenAnythingDashboardReviewRegistry
  @State private var openAnythingPaletteController: OpenAnythingPaletteWindowController
  @State private var globalHotKeyController: GlobalHotKeyController
  @State private var clipboardAutomationPolicyService: ClipboardAutomationPolicyService
  @State private var hasInstalledAppSceneServices = false
  @State private var hasBoundOpenAnythingExecutor = false
  @State private var settingsSelectedSection: SettingsSection
  @State private var settingsNavigationRequest: SettingsNavigationRequest?
  @State private var supervisorAuditTimelineDispatcher = SupervisorAuditTimelineFocusDispatcher()
  @State private var hasInstalledMainWindowLauncher = false
  @State private var hasScheduledInitialWindowRouting = false
  @State private var hasRunPerfScenario = false
  @State private var perfScenarioStatus: HarnessMonitorPerfScenarioStatus = .idle
  @State private var perfScenarioFailureReason: String?
  @State private var pendingPairingURL: URL?
  @State private var pendingPairingError: RemoteDaemonPairingInvitationError?
  @AppStorage(HarnessMonitorThemeDefaults.modeKey)
  var themeMode: HarnessMonitorThemeMode = .auto
  @AppStorage(HarnessMonitorTextSize.storageKey)
  var textSizeIndex = HarnessMonitorTextSize.defaultIndex
  @AppStorage(HarnessMonitorMenuBarDefaults.stateColorVariantsEnabledKey)
  var menuBarStateColorVariantsEnabled =
    HarnessMonitorMenuBarDefaults.stateColorVariantsEnabledDefault
  @AppStorage(HarnessMonitorLaunchBehavior.storageKey)
  var sessionWindowLaunchModeRawValue =
    HarnessMonitorLaunchBehavior.defaultValue.rawValue
  @AppStorage(OpenAnythingHotKeyDefaults.enabledKey)
  var globalOpenAnythingHotKeyEnabled = OpenAnythingHotKeyDefaults.enabledDefault
  @AppStorage(OpenAnythingHotKeyDefaults.descriptorKey)
  var globalOpenAnythingHotKeyDescriptor =
    OpenAnythingHotKeyDefaults.descriptorDefault.storageValue

  init() {
    HarnessMonitorPerfLaunchMetricsRecorder.bootstrap()

    // Rename `dashboard.dependencies.*` / `dependencies.*` / `settingsDependencies*`
    // keys to their `dashboard.reviews.*` / `reviews.*` / `settingsReviews*`
    // equivalents before any other code reads or registers defaults. The
    // helper is idempotent via a completion flag, so subsequent launches no-op.
    HarnessMonitorReviewsUserDefaultsMigration.runIfNeeded()

    Self.registerLaunchDefaults()

    let configuration = HarnessMonitorAppConfiguration.resolve()
    let isTestRun = Self.resolvedIsTestRun(configuration: configuration)
    // Preview/playground shells run an ad-hoc signed copy of the bundle from
    // /private/tmp and lack entitlements. Skip every filesystem/telemetry
    // side effect that the canvas does not need; the preview shell crashes
    // (libdispatch BUG, NSAssertion) when these touch sandboxed services.
    let runsLiveSideEffects = configuration.launchMode == .live && !isTestRun
    if runsLiveSideEffects {
      Self.scheduleLaunchFilesystemMaintenance(environment: configuration.environment)
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
    initialSessionWindowRoute = SessionWindowInitialRouteOverride.route(
      values: configuration.environment.values,
      isUITesting: configuration.isUITesting
    )
    let store = configuration.store
    mobileRelayRuntime = Self.makeMobileRelayRuntime(
      environment: configuration.environment,
      store: store,
      runsLiveSideEffects: runsLiveSideEffects
    )
    let windowNavigationHistory = GlobalWindowNavigationHistory(store: store)
    Self.bindSupervisorSurfacesIfNeeded(
      to: store,
      notificationController: notificationController,
      dockBadgeController: pendingDecisionsDockBadgeController,
      menuBarStatusController: menuBarStatusController
    )
    _store = State(initialValue: store)
    _menuBarStatusController = State(initialValue: menuBarStatusController)
    _sessionWindowPresenceTracker = State(initialValue: SessionWindowPresenceTracker())
    _windowCommandRouting = State(initialValue: WindowCommandRoutingState())
    GlobalWindowNavigationHistoryRegistry.current = windowNavigationHistory
    _windowNavigationHistory = State(initialValue: windowNavigationHistory)
    _mcpWindowCommandRegistrar = State(
      initialValue: HarnessMonitorMCPWindowCommandRegistrar(
        descriptors: HarnessMonitorMCPWindowCommandDescriptors.all
      )
    )
    let coordinator = OpenAnythingCorpusCoordinator()
    _openAnythingCoordinator = State(initialValue: coordinator)
    _openAnythingCorpusDriver = State(initialValue: OpenAnythingCorpusUpdateDriver())
    _openAnythingReviews = State(initialValue: OpenAnythingDashboardReviewRegistry())
    _openAnythingPaletteController = State(
      initialValue: OpenAnythingPaletteWindowController(model: coordinator.palette)
    )
    _globalHotKeyController = State(initialValue: GlobalHotKeyController())
    _clipboardAutomationPolicyService = State(initialValue: ClipboardAutomationPolicyService())
    _settingsSelectedSection = State(
      initialValue: SettingsRestorationDefaults.initialSelectedSection(
        fallback: configuration.settingsInitialSection,
        ignoresStoredValue: configuration.isUITesting || configuration.perfScenario != nil
      )
    )
    delegate.bind(store: store)
    mobileRelayRuntime?.start()
  }

  static func registerLaunchDefaults() {
    UserDefaults.standard.register(defaults: [
      "NSUseAnimatedFocusRing": false,
      SessionWindowKeyboardShortcutOverlaySettings.storageKey:
        SessionWindowKeyboardShortcutOverlaySettings.defaultValue,
      OpenAnythingHotKeyDefaults.enabledKey: OpenAnythingHotKeyDefaults.enabledDefault,
      OpenAnythingHotKeyDefaults.descriptorKey:
        OpenAnythingHotKeyDefaults.descriptorDefault.storageValue,
      OpenAnythingPreferencesDefaults.showPinnedKey:
        OpenAnythingPreferencesDefaults.showPinnedDefault,
      OpenAnythingPreferencesDefaults.showRecentKey:
        OpenAnythingPreferencesDefaults.showRecentDefault,
      OpenAnythingPreferencesDefaults.cmdClickBackgroundKey:
        OpenAnythingPreferencesDefaults.cmdClickBackgroundDefault,
      OpenAnythingPreferencesDefaults.restoreLastQueryKey:
        OpenAnythingPreferencesDefaults.restoreLastQueryDefault,
      MobileRelayPairingEndpointDefaults.storageKey:
        MobileRelayPairingEndpointDefaults.defaultValue,
    ])
  }

  static func resolvedIsTestRun(configuration: HarnessMonitorAppConfiguration) -> Bool {
    configuration.isUITesting
      || configuration.environment.isXCTestProcess
      || HarnessMonitorAppDelegate.isCurrentTestHarnessRun()
  }

  static func scheduleLaunchFilesystemMaintenance(
    environment: HarnessMonitorEnvironment
  ) {
    Task.detached(priority: .utility) {
      do {
        try HarnessMonitorPaths.ensureHarnessRootNonIndexable(using: environment)
      } catch {
        HarnessMonitorLogger.store.warning(
          "Failed to mark harness root non-indexable: \(String(describing: error), privacy: .public)"
        )
      }
      do {
        try HarnessMonitorPaths.migrateLegacyGeneratedCaches(using: environment)
      } catch {
        HarnessMonitorLogger.store.warning(
          "Failed to migrate generated caches: \(String(describing: error), privacy: .public)"
        )
      }
    }
  }

  var body: some Scene {
    dashboardWindowScene
    sessionWindowScene
    settingsWindowScene
    menuBarExtraScene
  }

  var appStore: HarnessMonitorStore {
    store
  }

  var appDelegate: HarnessMonitorAppDelegate {
    delegate
  }

  var appMenuBarStatusController: HarnessMonitorMenuBarStatusController {
    menuBarStatusController
  }

  var appSessionWindowPresenceTracker: SessionWindowPresenceTracker {
    sessionWindowPresenceTracker
  }

  var appWindowCommandRouting: WindowCommandRoutingState {
    windowCommandRouting
  }

  var appMCPWindowCommandRegistrar: HarnessMonitorMCPWindowCommandRegistrar {
    mcpWindowCommandRegistrar
  }

  var appWindowNavigationHistory: GlobalWindowNavigationHistory {
    windowNavigationHistory
  }

  var appOpenAnythingPalette: OpenAnythingPaletteModel {
    openAnythingCoordinator.palette
  }

  var appOpenAnythingCoordinator: OpenAnythingCorpusCoordinator {
    openAnythingCoordinator
  }

  var appOpenAnythingCorpusDriver: OpenAnythingCorpusUpdateDriver {
    openAnythingCorpusDriver
  }

  var appOpenAnythingLoadedSessionOverride: OpenAnythingLoadedSessionSnapshot? {
    get { openAnythingLoadedSessionOverride }
    nonmutating set { openAnythingLoadedSessionOverride = newValue }
  }

  var appOpenAnythingReviews: OpenAnythingDashboardReviewRegistry {
    openAnythingReviews
  }

  var appOpenAnythingPaletteController: OpenAnythingPaletteWindowController {
    openAnythingPaletteController
  }

  var hasBoundOpenAnythingExecutorFlag: Bool {
    get { hasBoundOpenAnythingExecutor }
    nonmutating set { hasBoundOpenAnythingExecutor = newValue }
  }

  var hasBoundOpenAnythingExecutorBinding: Binding<Bool> {
    Binding(
      get: { hasBoundOpenAnythingExecutor },
      set: { hasBoundOpenAnythingExecutor = $0 }
    )
  }

  var appGlobalHotKeyController: GlobalHotKeyController {
    globalHotKeyController
  }

  var appClipboardAutomationPolicyService: ClipboardAutomationPolicyService {
    clipboardAutomationPolicyService
  }

  var hasInstalledAppSceneServicesFlag: Bool {
    get { hasInstalledAppSceneServices }
    nonmutating set { hasInstalledAppSceneServices = newValue }
  }

  var appAuditTimelineDispatcher: SupervisorAuditTimelineFocusDispatcher {
    supervisorAuditTimelineDispatcher
  }

  var themeModeBinding: Binding<HarnessMonitorThemeMode> {
    $themeMode
  }

  var settingsSelectedSectionBinding: Binding<SettingsSection> {
    Binding {
      settingsSelectedSection
    } set: { newValue in
      guard settingsSelectedSection != newValue else {
        return
      }
      settingsSelectedSection = newValue
      SettingsRestorationDefaults.storeSelectedSection(newValue)
    }
  }

  var settingsNavigationRequestBinding: Binding<SettingsNavigationRequest?> {
    $settingsNavigationRequest
  }

  var hasRunPerfScenarioBinding: Binding<Bool> {
    $hasRunPerfScenario
  }

  var perfScenarioStatusBinding: Binding<HarnessMonitorPerfScenarioStatus> {
    $perfScenarioStatus
  }

  var perfScenarioFailureReasonBinding: Binding<String?> {
    $perfScenarioFailureReason
  }

  var pendingPairingURLValue: URL? {
    get { pendingPairingURL }
    nonmutating set { pendingPairingURL = newValue }
  }

  var pendingPairingErrorValue: RemoteDaemonPairingInvitationError? {
    get { pendingPairingError }
    nonmutating set { pendingPairingError = newValue }
  }

  var pendingPairingURLBinding: Binding<URL?> {
    $pendingPairingURL
  }

  var pendingPairingErrorBinding: Binding<RemoteDaemonPairingInvitationError?> {
    $pendingPairingError
  }

  var hasInstalledMainWindowLauncherFlag: Bool {
    get {
      hasInstalledMainWindowLauncher
    }
    nonmutating set {
      hasInstalledMainWindowLauncher = newValue
    }
  }

  var hasScheduledInitialWindowRoutingFlag: Bool {
    get {
      hasScheduledInitialWindowRouting
    }
    nonmutating set {
      hasScheduledInitialWindowRouting = newValue
    }
  }
}
