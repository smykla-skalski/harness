import AppKit
import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI
struct HarnessMonitorWindowRootView: View {
  let delegate: HarnessMonitorAppDelegate
  let store: HarnessMonitorStore
  let notifications: HarnessMonitorUserNotificationController
  let windowCommandRouting: WindowCommandRoutingState
  @Binding var themeMode: HarnessMonitorThemeMode
  @Binding var preferencesSelectedSection: PreferencesSection
  let perfScenario: HarnessMonitorPerfScenario?
  @Environment(\.openWindow)
  private var openWindow
  @Environment(\.openSettings)
  private var openSettings
  @AppStorage(HarnessMonitorBackdropDefaults.modeKey)
  private var backdropModeRawValue = HarnessMonitorBackdropMode.none.rawValue
  @AppStorage(HarnessMonitorBackgroundDefaults.imageKey)
  private var backgroundImageRawValue = HarnessMonitorBackgroundSelection.defaultSelection
    .storageValue
  #if HARNESS_FEATURE_LOTTIE
    @AppStorage(HarnessMonitorCornerAnimationDefaults.enabledKey)
    private var cornerAnimationEnabled = false
  #endif
  @State private var handledSettingsOpenRequestID = 0
  @State private var handledDecisionRequestTick = 0
  private let toolbarGlassReproConfiguration = ToolbarGlassReproConfiguration.current
  private var backdropMode: HarnessMonitorBackdropMode {
    HarnessMonitorBackdropMode(rawValue: backdropModeRawValue) ?? .none
  }
  private var backgroundImage: HarnessMonitorBackgroundSelection {
    HarnessMonitorBackgroundSelection.decode(backgroundImageRawValue)
  }
  var body: some View {
    Group {
      #if HARNESS_FEATURE_LOTTIE
        ContentView(
          store: store,
          showsCornerAnimation: cornerAnimationEnabled
        ) {
          HarnessMonitorAppLlamaAnimation()
        }
      #else
        ContentView(store: store)
      #endif
    }
    .writingToolsBehavior(.disabled)
    .modifier(
      HarnessMonitorPerfScenarioModifier(
        delegate: delegate,
        store: store,
        perfScenario: perfScenario
      )
    )
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
    .modifier(HarnessMonitorUITestAnimationModifier())
    .modifier(SupervisorUITestForceTickModifier(store: store))
    .onChange(of: notifications.settingsOpenRequestID) { _, requestID in
      guard requestID != handledSettingsOpenRequestID else {
        return
      }
      handledSettingsOpenRequestID = requestID
      preferencesSelectedSection = .notifications
      openSettings()
    }
    .task(id: notifications.decisionRequestTick) {
      routeDecisionWindowRequest(for: notifications.decisionRequestTick)
    }
    .onChange(of: notifications.decisionRequestTick) { _, tick in
      routeDecisionWindowRequest(for: tick)
    }
  }
  private func routeDecisionWindowRequest(for tick: Int) {
    guard tick != handledDecisionRequestTick,
      let decisionID = notifications.decisionRequestedID
    else {
      return
    }
    handledDecisionRequestTick = tick
    store.supervisorSelectedDecisionID = decisionID
    openWindow(id: HarnessMonitorWindowID.decisions)
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
  @Environment(\.openSettings)
  private var openSettings
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
        openSettings: openSettings
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
      openSettings: openSettings
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
  let windowCommandRouting: WindowCommandRoutingState
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
    windowCommandRouting: WindowCommandRoutingState,
    themeMode: Binding<HarnessMonitorThemeMode>,
    selectedSection: Binding<PreferencesSection>
  ) {
    self.store = store
    self.notifications = notifications
    self.windowCommandRouting = windowCommandRouting
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
    .frame(idealWidth: 860, idealHeight: 620)
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
    .modifier(PinchToZoomTextSizeModifier())
    .modifier(HarnessMonitorUITestAnimationModifier())
  }
}

struct AgentsWindowRootView: View {
  let store: HarnessMonitorStore
  let navigationBridge: AgentsWindowNavigationBridge
  let windowCommandRouting: WindowCommandRoutingState
  @Binding var themeMode: HarnessMonitorThemeMode
  @AppStorage(HarnessMonitorBackdropDefaults.modeKey)
  private var backdropModeRawValue = HarnessMonitorBackdropMode.none.rawValue
  @AppStorage(HarnessMonitorBackgroundDefaults.imageKey)
  private var backgroundImageRawValue = HarnessMonitorBackgroundSelection.defaultSelection
    .storageValue

  private var backdropMode: HarnessMonitorBackdropMode {
    HarnessMonitorBackdropMode(rawValue: backdropModeRawValue) ?? .none
  }

  private var backgroundImage: HarnessMonitorBackgroundSelection {
    HarnessMonitorBackgroundSelection.decode(backgroundImageRawValue)
  }

  private var commandRoutingStateText: String {
    let scopeLabel =
      switch windowCommandRouting.activeScope {
      case .agents:
        "agents"
      case .main:
        "main"
      case nil:
        "nil"
      }
    return [
      "scope=\(scopeLabel)",
      "canGoBack=\(navigationBridge.state.canGoBack)",
      "canGoForward=\(navigationBridge.state.canGoForward)",
    ].joined(separator: ",")
  }

  var body: some View {
    AgentsWindowView(store: store, navigationBridge: navigationBridge)
      .accessibilityIdentifier(HarnessMonitorAccessibility.agentsWindow)
      .writingToolsBehavior(.disabled)
      .frame(minWidth: 860, minHeight: 620)
      .modifier(
        HarnessMonitorWindowBackdropModifier(
          mode: backdropMode,
          backgroundImage: backgroundImage
        )
      )
      .modifier(
        WindowCommandScopeTrackingModifier(
          scope: .agents,
          routingState: windowCommandRouting
        )
      )
      .instantFocusRing()
      .modifier(
        HarnessMonitorSceneAppearanceModifier(
          themeMode: $themeMode,
          appliesPreferredColorScheme: true
        )
      )
      .modifier(PinchToZoomTextSizeModifier())
      .modifier(HarnessMonitorUITestAnimationModifier())
      .overlay {
        if HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled {
          AccessibilityTextMarker(
            identifier: HarnessMonitorAccessibility.agentsCommandRoutingState,
            text: commandRoutingStateText
          )
        }
      }
  }
}

private struct HarnessMonitorUITestAnimationModifier: ViewModifier {
  private static let isUITesting =
    ProcessInfo.processInfo.environment["HARNESS_MONITOR_UI_TESTS"] == "1"
  private static let keepAnimations =
    ProcessInfo.processInfo.environment["HARNESS_MONITOR_KEEP_ANIMATIONS"] == "1"

  func body(content: Content) -> some View {
    if Self.isUITesting && !Self.keepAnimations {
      content.transaction { $0.disablesAnimations = true }
    } else {
      content
    }
  }
}

private struct OptionalInstantFocusRingModifier: ViewModifier {
  let isEnabled: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if isEnabled {
      content.instantFocusRing()
    } else {
      content
    }
  }
}

private struct HarnessMonitorSceneAppearanceModifier: ViewModifier {
  @Binding var themeMode: HarnessMonitorThemeMode
  let appliesPreferredColorScheme: Bool
  @AppStorage(HarnessMonitorTextSize.storageKey)
  private var textSizeIndex = HarnessMonitorTextSize.defaultIndex
  @AppStorage(HarnessMonitorDateTimeConfiguration.timeZoneModeKey)
  private var timeZoneModeRawValue = HarnessMonitorDateTimeConfiguration.defaultTimeZoneModeRawValue
  @AppStorage(HarnessMonitorDateTimeConfiguration.customTimeZoneIdentifierKey)
  private var customTimeZoneIdentifier = HarnessMonitorDateTimeConfiguration
    .defaultCustomTimeZoneIdentifier

  private var dateTimeConfiguration: HarnessMonitorDateTimeConfiguration {
    HarnessMonitorDateTimeConfiguration(
      timeZoneModeRawValue: timeZoneModeRawValue,
      customTimeZoneIdentifier: customTimeZoneIdentifier
    )
  }

  func body(content: Content) -> some View {
    let normalizedTextSizeIndex = HarnessMonitorTextSize.normalizedIndex(textSizeIndex)

    content
      .environment(\.harnessTextSizeIndex, normalizedTextSizeIndex)
      .environment(\.fontScale, HarnessMonitorTextSize.scale(at: normalizedTextSizeIndex))
      .environment(
        \.harnessNativeFormControlFont,
        HarnessMonitorTextSize.nativeFormControlFont(at: normalizedTextSizeIndex)
      )
      .environment(
        \.harnessNativeFormControlSize,
        HarnessMonitorTextSize.controlSize(at: normalizedTextSizeIndex)
      )
      .environment(\.harnessDateTimeConfiguration, dateTimeConfiguration)
      .modifier(
        OptionalPreferredColorSchemeModifier(
          colorScheme: themeMode.colorScheme,
          isEnabled: appliesPreferredColorScheme
        )
      )
      .tint(HarnessMonitorTheme.accent)
  }
}
