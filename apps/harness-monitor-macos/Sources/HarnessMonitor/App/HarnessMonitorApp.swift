import AppKit
import HarnessMonitorKit
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
  let showsPolicyCanvasLab: Bool
  @State private var store: HarnessMonitorStore
  @State private var menuBarStatusController: HarnessMonitorMenuBarStatusController
  @State private var sessionWindowPresenceTracker: SessionWindowPresenceTracker
  @State private var windowCommandRouting: WindowCommandRoutingState
  @State private var windowNavigationHistory: GlobalWindowNavigationHistory
  @State private var mcpWindowCommandRegistrar: HarnessMonitorMCPWindowCommandRegistrar
  @State private var settingsSelectedSection: SettingsSection
  @State private var settingsNavigationRequest: SettingsNavigationRequest?
  @State private var hasInstalledMainWindowLauncher = false
  @State private var hasScheduledInitialWindowRouting = false
  @State private var hasRunPerfScenario = false
  @State private var perfScenarioStatus: HarnessMonitorPerfScenarioStatus = .idle
  @State private var perfScenarioFailureReason: String?
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

  init() {
    HarnessMonitorPerfLaunchMetricsRecorder.bootstrap()

    UserDefaults.standard.register(defaults: [
      "NSUseAnimatedFocusRing": false,
      SessionWindowKeyboardShortcutOverlaySettings.storageKey:
        SessionWindowKeyboardShortcutOverlaySettings.defaultValue,
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
    showsPolicyCanvasLab = configuration.showsPolicyCanvasLab
    let store = configuration.store
    let windowNavigationHistory = GlobalWindowNavigationHistory(store: store)
    Self.bindSupervisorSurfaces(
      to: store,
      notificationController: notificationController,
      dockBadgeController: pendingDecisionsDockBadgeController,
      menuBarStatusController: menuBarStatusController
    )
    _store = State(initialValue: store)
    _menuBarStatusController = State(initialValue: menuBarStatusController)
    _sessionWindowPresenceTracker = State(
      initialValue: SessionWindowPresenceTracker()
    )
    _windowCommandRouting = State(initialValue: WindowCommandRoutingState())
    GlobalWindowNavigationHistoryRegistry.current = windowNavigationHistory
    _windowNavigationHistory = State(initialValue: windowNavigationHistory)
    _mcpWindowCommandRegistrar = State(
      initialValue: HarnessMonitorMCPWindowCommandRegistrar(
        descriptors: HarnessMonitorMCPWindowCommandDescriptors.all
      )
    )
    _settingsSelectedSection = State(
      initialValue: SettingsRestorationDefaults.initialSelectedSection(
        fallback: configuration.settingsInitialSection,
        ignoresStoredValue: configuration.isUITesting || configuration.perfScenario != nil
      )
    )
    delegate.bind(store: store)
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
    policyCanvasLabWindowScene
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

  var themeModeBinding: Binding<HarnessMonitorThemeMode> {
    $themeMode
  }

  var settingsSelectedSectionBinding: Binding<SettingsSection> {
    Binding {
      settingsSelectedSection
    } set: { newValue in
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
