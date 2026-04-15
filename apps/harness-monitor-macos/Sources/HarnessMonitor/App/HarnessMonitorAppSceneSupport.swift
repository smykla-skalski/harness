import AppKit
import HarnessMonitorKit
import HarnessMonitorUI
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
  @AppStorage(HarnessMonitorBackdropDefaults.modeKey)
  private var backdropModeRawValue = HarnessMonitorBackdropMode.none.rawValue
  @AppStorage(HarnessMonitorBackgroundDefaults.imageKey)
  private var backgroundImageRawValue = HarnessMonitorBackgroundSelection.defaultSelection
    .storageValue
  @AppStorage(HarnessMonitorCornerAnimationDefaults.enabledKey)
  private var cornerAnimationEnabled = false
  @State private var handledSettingsOpenRequestID = 0
  private let toolbarGlassReproConfiguration = ToolbarGlassReproConfiguration.current

  private var backdropMode: HarnessMonitorBackdropMode {
    HarnessMonitorBackdropMode(rawValue: backdropModeRawValue) ?? .none
  }

  private var backgroundImage: HarnessMonitorBackgroundSelection {
    HarnessMonitorBackgroundSelection.decode(backgroundImageRawValue)
  }
  var body: some View {
    ContentView(
      store: store,
      showsCornerAnimation: cornerAnimationEnabled
    ) {
      HarnessMonitorAppLlamaAnimation()
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
    .onChange(of: notifications.settingsOpenRequestID) { _, requestID in
      guard requestID != handledSettingsOpenRequestID else {
        return
      }
      handledSettingsOpenRequestID = requestID
      preferencesSelectedSection = .notifications
      openWindow(id: HarnessMonitorWindowID.preferences)
    }
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

struct AgentTuiWindowRootView: View {
  let store: HarnessMonitorStore
  @ObservedObject var navigationBridge: AgentTuiWindowNavigationBridge
  @ObservedObject var windowCommandRouting: WindowCommandRoutingState
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
      case .agentTui:
        "agentTui"
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
    AgentTuiWindowView(store: store, navigationBridge: navigationBridge)
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
          scope: .agentTui,
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
            identifier: HarnessMonitorAccessibility.agentTuiCommandRoutingState,
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

private struct WindowCommandScopeTrackingModifier: ViewModifier {
  let scope: WindowNavigationScope?
  let routingState: WindowCommandRoutingState

  func body(content: Content) -> some View {
    content
      .background(WindowCommandScopeTrackingView(scope: scope, routingState: routingState))
  }
}

private struct WindowCommandScopeTrackingView: NSViewRepresentable {
  let scope: WindowNavigationScope?
  let routingState: WindowCommandRoutingState

  func makeNSView(context: Context) -> WindowCommandScopeTrackingNSView {
    let view = WindowCommandScopeTrackingNSView()
    view.alphaValue = 0
    view.setAccessibilityHidden(true)
    view.configure(scope: scope, routingState: routingState)
    return view
  }

  func updateNSView(_ nsView: WindowCommandScopeTrackingNSView, context: Context) {
    nsView.configure(scope: scope, routingState: routingState)
  }
}

private final class WindowCommandScopeTrackingNSView: NSView {
  private var scope: WindowNavigationScope?
  private weak var routingState: WindowCommandRoutingState?
  private var observedWindow: NSWindow?
  private var notificationTokens: [NSObjectProtocol] = []

  deinit {
    MainActor.assumeIsolated {
      tearDownWindowObservation()
    }
  }

  func configure(
    scope: WindowNavigationScope?,
    routingState: WindowCommandRoutingState
  ) {
    self.scope = scope
    self.routingState = routingState
    if let window {
      beginObserving(window: window)
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    beginObserving(window: window)
  }

  private func beginObserving(window: NSWindow?) {
    guard observedWindow !== window else {
      updateRoutingState()
      return
    }

    tearDownWindowObservation()
    observedWindow = window

    guard let window else {
      return
    }

    let notificationCenter = NotificationCenter.default
    notificationTokens = [
      notificationCenter.addObserver(
        forName: NSWindow.didBecomeKeyNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.activate(window: window)
        }
      },
      notificationCenter.addObserver(
        forName: NSWindow.willCloseNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.clear(window: window)
        }
      },
    ]

    updateRoutingState()
  }

  private func tearDownWindowObservation() {
    if let observedWindow {
      routingState?.clear(windowID: ObjectIdentifier(observedWindow))
    }
    notificationTokens.forEach(NotificationCenter.default.removeObserver)
    notificationTokens.removeAll()
    observedWindow = nil
  }

  private func updateRoutingState() {
    guard let window = observedWindow else {
      return
    }
    if window.isKeyWindow {
      activate(window: window)
    }
  }

  private func activate(window: NSWindow) {
    routingState?.activate(scope: scope, windowID: ObjectIdentifier(window))
  }

  private func clear(window: NSWindow) {
    routingState?.clear(windowID: ObjectIdentifier(window))
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

private struct PinchToZoomTextSizeModifier: ViewModifier {
  @AppStorage(HarnessMonitorTextSize.storageKey)
  private var textSizeIndex = HarnessMonitorTextSize.defaultIndex

  func body(content: Content) -> some View {
    content.gesture(
      MagnifyGesture(minimumScaleDelta: 0.05)
        .onEnded { value in
          let delta = HarnessMonitorTextSize.indexDelta(
            forMagnification: value.magnification,
            currentIndex: textSizeIndex
          )
          if delta != 0 {
            textSizeIndex += delta
          }
        }
    )
  }
}

private struct OptionalPreferredColorSchemeModifier: ViewModifier {
  let colorScheme: ColorScheme?
  let isEnabled: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if isEnabled {
      content.preferredColorScheme(colorScheme)
    } else {
      content
    }
  }
}
