import AppKit
import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct HarnessMonitorWindowRootView: View {
  let delegate: HarnessMonitorAppDelegate
  let store: HarnessMonitorStore
  let notifications: HarnessMonitorUserNotificationController
  let keyWindowObserver: KeyWindowObserver
  let acpAttentionState: AcpPermissionAttentionState
  let windowCommandRouting: WindowCommandRoutingState
  let mcpWindowCommandRegistrar: HarnessMonitorMCPWindowCommandRegistrar
  @Binding var themeMode: HarnessMonitorThemeMode
  @Binding var preferencesSelectedSection: PreferencesSection
  let perfScenario: HarnessMonitorPerfScenario?
  let defersInitialContentUntilBootstrap: Bool
  @Environment(\.openWindow)
  private var openWindow
  @AppStorage(HarnessMonitorBackdropDefaults.modeKey)
  private var backdropModeRawValue = HarnessMonitorBackdropMode.none.rawValue
  @AppStorage(HarnessMonitorBackgroundDefaults.imageKey)
  private var backgroundImageRawValue = HarnessMonitorBackgroundSelection.defaultSelection
    .storageValue
  #if HARNESS_FEATURE_LOTTIE
    @AppStorage(HarnessMonitorCornerAnimationDefaults.enabledKey)
    private var cornerAnimationEnabled = false
  #endif
  @State private var completedInitialBootstrap = false
  @State private var handledSettingsOpenRequestID = 0
  private let toolbarGlassReproConfiguration = ToolbarGlassReproConfiguration.current
  private var backdropMode: HarnessMonitorBackdropMode {
    HarnessMonitorBackdropMode(rawValue: backdropModeRawValue) ?? .none
  }
  private var backgroundImage: HarnessMonitorBackgroundSelection {
    HarnessMonitorBackgroundSelection.decode(backgroundImageRawValue)
  }

  private var shouldShowBootstrapPlaceholder: Bool {
    defersInitialContentUntilBootstrap && !completedInitialBootstrap
  }

  var body: some View {
    rootContent
      .writingToolsBehavior(.disabled)
      .frame(minWidth: 900, minHeight: 600)
      .modifier(
        OptionalInstantFocusRingModifier(
          isEnabled: toolbarGlassReproConfiguration.usesInstantFocusRing
        )
      )
      .modifier(
        HarnessMonitorSceneAppearanceModifier(
          themeMode: $themeMode,
          appliesPreferredColorScheme: !toolbarGlassReproConfiguration.disablesPreferredColorScheme
        )
      )
      .modifier(PinchToZoomTextSizeModifier())
      .modifier(
        HarnessMonitorWindowBackdropModifier(
          mode: backdropMode,
          backgroundImage: backgroundImage
        )
      )
      .modifier(
        WindowCommandScopeTrackingModifier(
          scope: .main,
          routingState: windowCommandRouting
        )
      )
      .harnessMonitorMCPWindowCommands(registrar: mcpWindowCommandRegistrar)
      .modifier(HarnessMonitorUITestAnimationModifier())
      .acpPermissionAttentionScene(
        store: store,
        notifications: notifications,
        attentionState: acpAttentionState,
        windowID: HarnessMonitorWindowID.main
      )
      .modifier(WorkspaceToolbarUITestForceTickModifier(store: store))
      .task(id: shouldShowBootstrapPlaceholder) {
        await bootstrapDeferredContentIfNeeded()
      }
      .onChange(of: notifications.settingsOpenRequestID) { _, requestID in
        guard requestID != handledSettingsOpenRequestID else {
          return
        }
        handledSettingsOpenRequestID = requestID
        preferencesSelectedSection = .notifications
        openWindow(id: HarnessMonitorWindowID.preferences)
      }
  }

  @ViewBuilder private var rootContent: some View {
    if shouldShowBootstrapPlaceholder {
      HarnessMonitorBootstrapPlaceholderView()
    } else {
      liveContent
    }
  }

  @ViewBuilder private var liveContent: some View {
    Group {
      #if HARNESS_FEATURE_LOTTIE
        ContentView(
          store: store,
          keyWindowObserver: keyWindowObserver,
          showsCornerAnimation: cornerAnimationEnabled
        ) {
          HarnessMonitorAppLlamaAnimation()
        }
      #else
        ContentView(store: store, keyWindowObserver: keyWindowObserver)
      #endif
    }
    .modifier(
      HarnessMonitorPerfScenarioModifier(
        delegate: delegate,
        store: store,
        perfScenario: perfScenario
      )
    )
  }

  private func bootstrapDeferredContentIfNeeded() async {
    guard shouldShowBootstrapPlaceholder else {
      return
    }
    delegate.bind(store: store)
    await store.bootstrapIfNeeded()
    completedInitialBootstrap = true
  }
}

private struct HarnessMonitorBootstrapPlaceholderView: View {
  var body: some View {
    Color.clear
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityHidden(true)
  }
}
private enum HarnessMonitorPerfScenarioStatus: String {
  case idle
  case bootstrapping
  case running
  case completed
}

private struct HarnessMonitorPerfScenarioModifier: ViewModifier {
  let delegate: HarnessMonitorAppDelegate
  let store: HarnessMonitorStore
  let perfScenario: HarnessMonitorPerfScenario?
  @Environment(\.openWindow)
  private var openWindow
  @State private var hasRunPerfScenario = false
  @State private var perfScenarioStatus: HarnessMonitorPerfScenarioStatus = .idle
  private var perfScenarioStateText: String? {
    guard shouldPublishPerfScenarioState,
      let perfScenario
    else {
      return nil
    }
    return "scenario=\(perfScenario.rawValue), status=\(perfScenarioStatus.rawValue)"
  }
  private var shouldPublishPerfScenarioState: Bool {
    HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled
  }
  func body(content: Content) -> some View {
    content
      .overlay {
        if let perfScenarioStateText {
          AccessibilityTextMarker(
            identifier: HarnessMonitorAccessibility.perfScenarioState,
            text: perfScenarioStateText
          )
        }
      }
      .task {
        await runPerfScenarioIfNeeded()
      }
  }
  private func runPerfScenarioIfNeeded() async {
    delegate.bind(store: store)
    guard let perfScenario else {
      await store.bootstrapIfNeeded()
      return
    }
    guard !hasRunPerfScenario else {
      return
    }
    hasRunPerfScenario = true

    if perfScenario.includesBootstrapInMeasurement {
      publishPerfScenarioStatus(.running)
      await HarnessMonitorPerfDriver.run(
        scenario: perfScenario,
        store: store,
        openWindow: openWindow
      )
      publishPerfScenarioStatus(.completed)
      return
    }
    publishPerfScenarioStatus(.bootstrapping)
    await store.bootstrapIfNeeded()
    publishPerfScenarioStatus(.running)
    await HarnessMonitorPerfDriver.run(
      scenario: perfScenario,
      store: store,
      openWindow: openWindow
    )
    publishPerfScenarioStatus(.completed)
  }
  private func publishPerfScenarioStatus(_ status: HarnessMonitorPerfScenarioStatus) {
    guard shouldPublishPerfScenarioState else {
      return
    }
    perfScenarioStatus = status
  }
}

struct HarnessMonitorSettingsRootView: View {
  let store: HarnessMonitorStore
  let notifications: HarnessMonitorUserNotificationController
  let acpAttentionState: AcpPermissionAttentionState
  let windowCommandRouting: WindowCommandRoutingState
  let mcpWindowCommandRegistrar: HarnessMonitorMCPWindowCommandRegistrar
  @Binding var themeMode: HarnessMonitorThemeMode
  @Binding var selectedSection: PreferencesSection
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
    selectedSection: Binding<PreferencesSection>
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
    PreferencesView(
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
    .instantFocusRing()
    .modifier(
      HarnessMonitorSceneAppearanceModifier(
        themeMode: $themeMode,
        appliesPreferredColorScheme: true
      )
    )
    .modifier(
      WindowCommandScopeTrackingModifier(
        scope: nil,
        routingState: windowCommandRouting
      )
    )
    .harnessMonitorMCPWindowCommands(registrar: mcpWindowCommandRegistrar)
    .modifier(PinchToZoomTextSizeModifier())
    .modifier(HarnessMonitorUITestAnimationModifier())
  }
}
