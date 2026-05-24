import AppKit
import HarnessMonitorKit
import HarnessMonitorMacRelay
import HarnessMonitorUIPreviewable
import SwiftUI

struct DashboardWindowRootView: View {
  static let minimumSize = CGSize(width: 900, height: 600)
  let delegate: HarnessMonitorAppDelegate
  let store: HarnessMonitorStore
  let notifications: HarnessMonitorUserNotificationController
  let keyWindowObserver: KeyWindowObserver
  let acpAttentionState: AcpPermissionAttentionState
  let windowCommandRouting: WindowCommandRoutingState
  let windowNavigationHistory: GlobalWindowNavigationHistory
  let mcpWindowCommandRegistrar: HarnessMonitorMCPWindowCommandRegistrar
  @Binding var themeMode: HarnessMonitorThemeMode
  @Binding var settingsSelectedSection: SettingsSection
  @Binding var settingsNavigationRequest: SettingsNavigationRequest?
  let supervisorAuditTimelineDispatcher: SupervisorAuditTimelineFocusDispatcher
  let perfScenario: HarnessMonitorPerfScenario?
  @Binding var hasRunPerfScenario: Bool
  @Binding var perfScenarioStatus: HarnessMonitorPerfScenarioStatus
  @Binding var perfScenarioFailureReason: String?
  let defersInitialContentUntilBootstrap: Bool
  let presentOpenAnything: @MainActor @Sendable () -> Void
  let setOpenAnythingQuery: @MainActor @Sendable (String) -> Void
  @Environment(\.openWindow)
  var openWindow
  @State private var completedInitialBootstrap = false
  @State private var handledSettingsOpenRequestID = 0

  var shouldShowBootstrapPlaceholder: Bool {
    defersInitialContentUntilBootstrap
      && perfScenario == nil
      && !completedInitialBootstrap
  }

  private var hostsSharedShellPresentation: Bool {
    keyWindowObserver.isKey(windowID: HarnessMonitorWindowID.dashboard)
  }

  var shouldPublishPerfScenarioState: Bool {
    HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled
  }

  var perfScenarioStateText: String? {
    resolvedPerfScenarioStateText(
      perfScenario: perfScenario,
      status: perfScenarioStatus,
      failureReason: perfScenarioFailureReason,
      publishesState: shouldPublishPerfScenarioState
    )
  }

  var contentReadiness: WindowContentReadiness {
    WindowContentReadiness(
      isReady: !shouldShowBootstrapPlaceholder,
      stateLabel: shouldShowBootstrapPlaceholder ? "dashboard-cache-deferred" : "ready",
      placeholder: .clear,
      prepare: { await bootstrapDeferredContentIfNeeded() }
    )
  }

  var body: some View {
    HarnessMonitorWindowShell(
      windowID: HarnessMonitorWindowID.dashboard,
      windowTitle: "Dashboard",
      scope: .main,
      minimumSize: Self.minimumSize,
      accessibilityIdentifier: HarnessMonitorAccessibility.dashboardWindowRoot,
      keyWindowObserver: keyWindowObserver,
      windowCommandRouting: windowCommandRouting,
      mcpWindowCommandRegistrar: mcpWindowCommandRegistrar,
      themeMode: $themeMode,
      contentReadiness: contentReadiness,
      windowToolbarBackgroundVisibility: .automatic,
      toast: store.toast
    ) {
      liveContent
    }
    .suppressToolbarBaselineSeparator(
      markedAs: HarnessMonitorAccessibility.dashboardToolbarSeparatorSuppressed
    )
    .modifier(WorkspaceToolbarUITestForceTickModifier(store: store))
    .modifier(
      HarnessMonitorConfirmationDialogModifier(
        store: store,
        shellUI: store.contentUI.shell,
        isEnabled: hostsSharedShellPresentation
      )
    )
    .modifier(
      HarnessMonitorSheetModifier(
        store: store,
        shellUI: store.contentUI.shell,
        isEnabled: hostsSharedShellPresentation
      )
    )
    .acpPermissionAttentionScene(
      store: store,
      notifications: notifications,
      attentionState: acpAttentionState,
      windowID: HarnessMonitorWindowID.dashboard
    )
    .modifier(PerfScenarioStateMarker(text: perfScenarioStateText))
    .onChange(of: notifications.settingsOpenRequestID) { _, requestID in
      guard requestID != handledSettingsOpenRequestID else {
        return
      }
      handledSettingsOpenRequestID = requestID
      settingsSelectedSection = .notifications
      openWindow(id: HarnessMonitorWindowID.settings)
    }
  }

  @ViewBuilder var liveContent: some View {
    DashboardWindowView(
      store: store,
      dashboardUI: store.contentUI.dashboard,
      sessionCatalog: store.sessionIndex.catalog,
      history: windowNavigationHistory
    )
    .environment(
      \.openTaskBoardSettings,
      OpenTaskBoardSettingsAction {
        settingsSelectedSection = .taskBoard
        settingsNavigationRequest = SettingsNavigationRequest(target: .taskBoard($0))
        openWindow(id: HarnessMonitorWindowID.settings)
      }
    )
    .environment(
      \.openSettingsSection,
      OpenSettingsSectionAction { section in
        settingsSelectedSection = section
        settingsNavigationRequest = SettingsNavigationRequest(target: .section(section))
        openWindow(id: HarnessMonitorWindowID.settings)
      }
    )
    .modifier(
      SupervisorAuditTimelineSceneModifier(
        settingsSelectedSection: $settingsSelectedSection,
        settingsNavigationRequest: $settingsNavigationRequest,
        dispatcher: supervisorAuditTimelineDispatcher
      )
    )
    .modifier(
      HarnessMonitorPerfScenarioModifier(
        delegate: delegate,
        store: store,
        perfScenario: perfScenario,
        hasRunPerfScenario: $hasRunPerfScenario,
        perfScenarioStatus: $perfScenarioStatus,
        perfScenarioFailureReason: $perfScenarioFailureReason,
        presentOpenAnything: presentOpenAnything,
        setOpenAnythingQuery: setOpenAnythingQuery
      )
    )
    .toolbar {}
  }

  @MainActor
  func bootstrapDeferredContentIfNeeded() async {
    guard shouldShowBootstrapPlaceholder else {
      return
    }
    delegate.bind(store: store)
    await store.bootstrapIfNeeded()
    await store.prepareOpenRecentSessions()
    completedInitialBootstrap = true
  }
}

enum HarnessMonitorPerfScenarioStatus: String {
  case idle
  case bootstrapping
  case running
  case completed
  case failed
}

func resolvedPerfScenarioStateText(
  perfScenario: HarnessMonitorPerfScenario?,
  status: HarnessMonitorPerfScenarioStatus,
  failureReason: String?,
  publishesState: Bool
) -> String? {
  guard publishesState, let perfScenario else {
    return nil
  }
  var fields = [
    "scenario=\(perfScenario.rawValue)",
    "status=\(status.rawValue)",
  ]
  fields.append(contentsOf: perfVisualSettingsStateFields())
  if let failureReason {
    fields.append("reason=\(failureReason)")
  }
  return fields.joined(separator: ", ")
}

struct HarnessMonitorPerfScenarioModifier: ViewModifier {
  let delegate: HarnessMonitorAppDelegate
  let store: HarnessMonitorStore
  let perfScenario: HarnessMonitorPerfScenario?
  @Binding var hasRunPerfScenario: Bool
  @Binding var perfScenarioStatus: HarnessMonitorPerfScenarioStatus
  @Binding var perfScenarioFailureReason: String?
  let presentOpenAnything: @MainActor @Sendable () -> Void
  let setOpenAnythingQuery: @MainActor @Sendable (String) -> Void
  @Environment(\.openWindow)
  var openWindow
  var shouldPublishPerfScenarioState: Bool {
    HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled
  }

  func body(content: Content) -> some View {
    content
      .task {
        await runPerfScenarioIfNeeded()
      }
  }
  func runPerfScenarioIfNeeded() async {
    delegate.bind(store: store)
    HarnessMonitorUITestTrace.record(
      component: "perf.scenario",
      event: "task.start",
      details: [
        "scenario": perfScenario?.rawValue ?? "none",
        "publishes_marker": shouldPublishPerfScenarioState ? "true" : "false",
      ]
    )
    guard let perfScenario else {
      await store.bootstrapIfNeeded()
      await store.prepareOpenRecentSessions()
      return
    }
    guard !hasRunPerfScenario else {
      return
    }
    hasRunPerfScenario = true

    if perfScenario.includesBootstrapInMeasurement {
      publishPerfScenarioStatus(.running)
      let result = await HarnessMonitorPerfDriver.run(
        scenario: perfScenario,
        store: store,
        openWindow: openWindow,
        presentOpenAnything: presentOpenAnything,
        setOpenAnythingQuery: setOpenAnythingQuery
      )
      publishPerfScenarioResult(result)
      return
    }
    publishPerfScenarioStatus(.bootstrapping)
    await store.bootstrapIfNeeded()
    publishPerfScenarioStatus(.running)
    let result = await HarnessMonitorPerfDriver.run(
      scenario: perfScenario,
      store: store,
      openWindow: openWindow,
      presentOpenAnything: presentOpenAnything,
      setOpenAnythingQuery: setOpenAnythingQuery
    )
    publishPerfScenarioResult(result)
  }
  func publishPerfScenarioStatus(_ status: HarnessMonitorPerfScenarioStatus) {
    guard shouldPublishPerfScenarioState else {
      return
    }
    perfScenarioStatus = status
    if let perfScenario {
      HarnessMonitorUITestTrace.record(
        component: "perf.scenario",
        event: "status",
        details: [
          "scenario": perfScenario.rawValue,
          "status": status.rawValue,
        ]
      )
    }
    if status == .running, let perfScenario {
      HarnessMonitorPerfLaunchMetricsRecorder.recordScenarioReady(
        windowID: HarnessMonitorWindowID.dashboard,
        stateLabel: status.rawValue,
        includesBootstrapInScenarioMeasurement: perfScenario.includesBootstrapInMeasurement
      )
    }
    if status != .failed {
      perfScenarioFailureReason = nil
    }
  }

  func publishPerfScenarioResult(_ result: HarnessMonitorPerfDriver.ScenarioResult) {
    switch result {
    case .completed:
      publishPerfScenarioStatus(.completed)
    case .failed(let reason):
      perfScenarioFailureReason = reason
      publishPerfScenarioStatus(.failed)
    }
  }
}

struct HarnessMonitorSettingsRootView: View {
  let store: HarnessMonitorStore
  let notifications: HarnessMonitorUserNotificationController
  let acpAttentionState: AcpPermissionAttentionState
  let windowCommandRouting: WindowCommandRoutingState
  let mcpWindowCommandRegistrar: HarnessMonitorMCPWindowCommandRegistrar
  let mobileRelayRuntime: MobileMacRelayRuntime?
  @Binding var themeMode: HarnessMonitorThemeMode
  @Binding var selectedSection: SettingsSection
  @Binding var navigationRequest: SettingsNavigationRequest?
  @AppStorage(HarnessMonitorBackdropDefaults.modeKey)
  var backdropModeRawValue = HarnessMonitorBackdropMode.none.rawValue
  @AppStorage(HarnessMonitorBackgroundDefaults.imageKey)
  var backgroundImageRawValue = HarnessMonitorBackgroundSelection.defaultSelection
    .storageValue

  init(
    store: HarnessMonitorStore,
    notifications: HarnessMonitorUserNotificationController,
    acpAttentionState: AcpPermissionAttentionState,
    windowCommandRouting: WindowCommandRoutingState,
    mcpWindowCommandRegistrar: HarnessMonitorMCPWindowCommandRegistrar,
    mobileRelayRuntime: MobileMacRelayRuntime?,
    themeMode: Binding<HarnessMonitorThemeMode>,
    selectedSection: Binding<SettingsSection>,
    navigationRequest: Binding<SettingsNavigationRequest?>
  ) {
    self.store = store
    self.notifications = notifications
    self.acpAttentionState = acpAttentionState
    self.windowCommandRouting = windowCommandRouting
    self.mcpWindowCommandRegistrar = mcpWindowCommandRegistrar
    self.mobileRelayRuntime = mobileRelayRuntime
    _themeMode = themeMode
    _selectedSection = selectedSection
    _navigationRequest = navigationRequest
  }

  var backdropMode: HarnessMonitorBackdropMode {
    HarnessMonitorBackdropMode(rawValue: backdropModeRawValue) ?? .none
  }

  var backgroundImage: HarnessMonitorBackgroundSelection {
    HarnessMonitorBackgroundSelection.decode(backgroundImageRawValue)
  }

  var mobilePairingContent: (@MainActor @Sendable () -> AnyView)? {
    guard let mobileRelayRuntime else {
      return nil
    }
    return { @MainActor @Sendable in
      AnyView(MobileRelayPairingSettingsPanel(runtime: mobileRelayRuntime))
    }
  }

  var body: some View {
    SettingsView(
      store: store,
      notifications: notifications,
      mobilePairingContent: mobilePairingContent,
      themeMode: $themeMode,
      selectedSection: $selectedSection,
      navigationRequest: $navigationRequest
    )
    .writingToolsBehavior(.disabled)
    .frame(minWidth: 680, minHeight: 440)
    .modifier(
      HarnessMonitorWindowBackdropModifier(
        mode: backdropMode,
        backgroundImage: backgroundImage
      )
    )
    .modifier(
      HarnessMonitorSceneAppearanceModifier(
        themeMode: $themeMode,
        appliesPreferredColorScheme: true
      )
    )
    .modifier(
      WindowCommandScopeTrackingModifier(
        scope: nil,
        routingState: windowCommandRouting,
        sessionID: nil,
        windowID: HarnessMonitorWindowID.settings
      )
    )
    .harnessMonitorMCPWindowCommands(registrar: mcpWindowCommandRegistrar)
    .modifier(PinchToZoomTextSizeModifier())
    .modifier(HarnessMonitorUITestAnimationModifier())
  }
}
