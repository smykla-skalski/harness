import AppKit
import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct HarnessMonitorWindowRootView: View {
  private static let minimumSize = CGSize(width: 900, height: 600)

  let delegate: HarnessMonitorAppDelegate
  let store: HarnessMonitorStore
  let notifications: HarnessMonitorUserNotificationController
  let keyWindowObserver: KeyWindowObserver
  let acpAttentionState: AcpPermissionAttentionState
  let windowCommandRouting: WindowCommandRoutingState
  let mcpWindowCommandRegistrar: HarnessMonitorMCPWindowCommandRegistrar
  @Binding var themeMode: HarnessMonitorThemeMode
  @Binding var settingsSelectedSection: SettingsSection
  let perfScenario: HarnessMonitorPerfScenario?
  let defersInitialContentUntilBootstrap: Bool
  @Environment(\.openWindow)
  private var openWindow
  #if HARNESS_FEATURE_LOTTIE
    @AppStorage(HarnessMonitorCornerAnimationDefaults.enabledKey)
    private var cornerAnimationEnabled = false
  #endif
  @State private var completedInitialBootstrap = false
  @State private var handledSettingsOpenRequestID = 0

  private var shouldShowBootstrapPlaceholder: Bool {
    defersInitialContentUntilBootstrap && !completedInitialBootstrap
  }

  private var hostsSharedShellPresentation: Bool {
    keyWindowObserver.isKey(windowID: HarnessMonitorWindowID.openRecent)
  }

  private var contentReadiness: WindowContentReadiness {
    WindowContentReadiness(
      isReady: !shouldShowBootstrapPlaceholder,
      stateLabel: shouldShowBootstrapPlaceholder ? "welcome-cache-deferred" : "ready",
      placeholder: .clear,
      prepare: { await bootstrapDeferredContentIfNeeded() }
    )
  }

  var body: some View {
    HarnessMonitorWindowShell(
      windowID: HarnessMonitorWindowID.openRecent,
      windowTitle: "Open Recent Session",
      scope: .main,
      minimumSize: Self.minimumSize,
      keyWindowObserver: keyWindowObserver,
      windowCommandRouting: windowCommandRouting,
      mcpWindowCommandRegistrar: mcpWindowCommandRegistrar,
      themeMode: $themeMode,
      contentReadiness: contentReadiness,
      windowToolbarBackgroundVisibility: nil,
      toast: store.toast
    ) {
      liveContent
    }
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
      windowID: HarnessMonitorWindowID.openRecent
    )
    .onChange(of: notifications.settingsOpenRequestID) { _, requestID in
      guard requestID != handledSettingsOpenRequestID else {
        return
      }
      handledSettingsOpenRequestID = requestID
      settingsSelectedSection = .notifications
      openWindow(id: HarnessMonitorWindowID.settings)
    }
  }

  @ViewBuilder private var liveContent: some View {
    OpenRecentView(store: store)
      .modifier(
        HarnessMonitorPerfScenarioModifier(
          delegate: delegate,
          store: store,
          perfScenario: perfScenario
        )
      )
  }

  @MainActor
  private func bootstrapDeferredContentIfNeeded() async {
    guard shouldShowBootstrapPlaceholder else {
      return
    }
    delegate.bind(store: store)
    await store.prepareOpenRecentSessions()
    completedInitialBootstrap = true
  }
}

private enum HarnessMonitorPerfScenarioStatus: String {
  case idle
  case bootstrapping
  case running
  case completed
  case failed
}

private struct HarnessMonitorPerfScenarioModifier: ViewModifier {
  let delegate: HarnessMonitorAppDelegate
  let store: HarnessMonitorStore
  let perfScenario: HarnessMonitorPerfScenario?
  @Environment(\.openWindow)
  private var openWindow
  @State private var hasRunPerfScenario = false
  @State private var perfScenarioStatus: HarnessMonitorPerfScenarioStatus = .idle
  @State private var perfScenarioFailureReason: String?
  private var perfScenarioStateText: String? {
    guard shouldPublishPerfScenarioState,
      let perfScenario
    else {
      return nil
    }
    var fields = [
      "scenario=\(perfScenario.rawValue)",
      "status=\(perfScenarioStatus.rawValue)",
    ]
    if let perfScenarioFailureReason {
      fields.append("reason=\(perfScenarioFailureReason)")
    }
    return fields.joined(separator: ", ")
  }
  private var shouldPublishPerfScenarioState: Bool {
    HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled
  }
  func body(content: Content) -> some View {
    content
      .modifier(PerfScenarioStateMarker(text: perfScenarioStateText))
      .task {
        await runPerfScenarioIfNeeded()
      }
  }
  private func runPerfScenarioIfNeeded() async {
    delegate.bind(store: store)
    guard let perfScenario else {
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
        openWindow: openWindow
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
      openWindow: openWindow
    )
    publishPerfScenarioResult(result)
  }
  private func publishPerfScenarioStatus(_ status: HarnessMonitorPerfScenarioStatus) {
    guard shouldPublishPerfScenarioState else {
      return
    }
    perfScenarioStatus = status
    if status != .failed {
      perfScenarioFailureReason = nil
    }
  }

  private func publishPerfScenarioResult(_ result: HarnessMonitorPerfDriver.ScenarioResult) {
    switch result {
    case .completed:
      publishPerfScenarioStatus(.completed)
    case .failed(let reason):
      perfScenarioFailureReason = reason
      publishPerfScenarioStatus(.failed)
    }
  }
}

private struct PerfScenarioStateMarker: ViewModifier {
  let text: String?

  @ViewBuilder
  func body(content: Content) -> some View {
    if let text {
      content.overlay {
        AccessibilityTextMarker(
          identifier: HarnessMonitorAccessibility.perfScenarioState,
          text: text
        )
      }
    } else {
      content
    }
  }
}

struct HarnessMonitorSettingsRootView: View {
  let store: HarnessMonitorStore
  let notifications: HarnessMonitorUserNotificationController
  let acpAttentionState: AcpPermissionAttentionState
  let windowCommandRouting: WindowCommandRoutingState
  let mcpWindowCommandRegistrar: HarnessMonitorMCPWindowCommandRegistrar
  @Binding var themeMode: HarnessMonitorThemeMode
  @Binding var selectedSection: SettingsSection
  @AppStorage(HarnessMonitorBackdropDefaults.modeKey)
  private var backdropModeRawValue = HarnessMonitorBackdropMode.none.rawValue
  @AppStorage(HarnessMonitorBackgroundDefaults.imageKey)
  private var backgroundImageRawValue = HarnessMonitorBackgroundSelection.defaultSelection
    .storageValue

  init(
    store: HarnessMonitorStore,
    notifications: HarnessMonitorUserNotificationController,
    acpAttentionState: AcpPermissionAttentionState,
    windowCommandRouting: WindowCommandRoutingState,
    mcpWindowCommandRegistrar: HarnessMonitorMCPWindowCommandRegistrar,
    themeMode: Binding<HarnessMonitorThemeMode>,
    selectedSection: Binding<SettingsSection>
  ) {
    self.store = store
    self.notifications = notifications
    self.acpAttentionState = acpAttentionState
    self.windowCommandRouting = windowCommandRouting
    self.mcpWindowCommandRegistrar = mcpWindowCommandRegistrar
    _themeMode = themeMode
    _selectedSection = selectedSection
  }

  private var backdropMode: HarnessMonitorBackdropMode {
    HarnessMonitorBackdropMode(rawValue: backdropModeRawValue) ?? .none
  }

  private var backgroundImage: HarnessMonitorBackgroundSelection {
    HarnessMonitorBackgroundSelection.decode(backgroundImageRawValue)
  }

  var body: some View {
    SettingsView(
      store: store,
      notifications: notifications,
      themeMode: $themeMode,
      selectedSection: $selectedSection
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
        sessionID: nil
      )
    )
    .harnessMonitorMCPWindowCommands(registrar: mcpWindowCommandRegistrar)
    .modifier(PinchToZoomTextSizeModifier())
    .modifier(HarnessMonitorUITestAnimationModifier())
  }
}
