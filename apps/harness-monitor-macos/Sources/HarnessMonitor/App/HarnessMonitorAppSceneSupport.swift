import AppKit
import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct HarnessMonitorWindowRootView: View {
  let delegate: HarnessMonitorAppDelegate
  let store: HarnessMonitorStore
  let notifications: HarnessMonitorUserNotificationController
  let acpAttentionState: AcpPermissionAttentionState
  let windowCommandRouting: WindowCommandRoutingState
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
      .modifier(HarnessMonitorUITestAnimationModifier())
      .acpPermissionAttentionScene(
        store: store,
        notifications: notifications,
        attentionState: acpAttentionState,
        windowID: HarnessMonitorWindowID.main
      )
      .modifier(SupervisorUITestForceTickModifier(store: store))
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
          showsCornerAnimation: cornerAnimationEnabled
        ) {
          HarnessMonitorAppLlamaAnimation()
        }
      #else
        ContentView(store: store)
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
    themeMode: Binding<HarnessMonitorThemeMode>,
    selectedSection: Binding<PreferencesSection>
  ) {
    self.store = store
    self.notifications = notifications
    self.acpAttentionState = acpAttentionState
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

struct AgentsWindowRootView: View {
  let store: HarnessMonitorStore
  let notifications: HarnessMonitorUserNotificationController
  let acpAttentionState: AcpPermissionAttentionState
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

@MainActor
@Observable
final class AcpPermissionAttentionState {
  private enum PreviewContextOverride: String {
    case foreground
    case hidden
  }

  private static let previewContextEnvironmentKey = "HARNESS_MONITOR_PREVIEW_ACP_ATTENTION_CONTEXT"

  var activeToast: AcpPermissionAttentionEvent?

  private let keyWindowObserver: KeyWindowObserver
  @ObservationIgnored private let notifications: HarnessMonitorUserNotificationController
  @ObservationIgnored private let previewContextOverride: PreviewContextOverride?
  @ObservationIgnored private var handledBatchIDs: Set<String> = []
  @ObservationIgnored private var deliveringBatchIDs: Set<String> = []
  @ObservationIgnored private var handledDecisionRequestTick = 0
  private var routeEventTick = 0
  private var lastRouteSource = "none"
  private var lastRouteDecisionID: String?
  private var lastRouteBatchID: String?

  init(
    keyWindowObserver: KeyWindowObserver,
    notifications: HarnessMonitorUserNotificationController
  ) {
    self.keyWindowObserver = keyWindowObserver
    self.notifications = notifications
    self.previewContextOverride = Self.resolvePreviewContextOverride()
  }

  var routingToken: String {
    [
      keyWindowObserver.snapshot.routingToken,
      "override=\(previewContextOverride?.rawValue ?? "live")",
    ].joined(separator: ",")
  }

  var routeStateText: String {
    [
      "source=\(lastRouteSource)",
      "decision=\(lastRouteDecisionID ?? "nil")",
      "batch=\(lastRouteBatchID ?? "nil")",
      "tick=\(routeEventTick)",
    ].joined(separator: " ")
  }

  func reconcile(store: HarnessMonitorStore) {
    let currentBatchIDs = Set(store.acpPermissionAttentionEvents.map(\.batchID))
    handledBatchIDs.formIntersection(currentBatchIDs)
    deliveringBatchIDs.formIntersection(currentBatchIDs)
    if let activeToast, !currentBatchIDs.contains(activeToast.batchID) {
      self.activeToast = nil
    }

    guard
      let nextAttention = store.acpPermissionAttentionEvents.first(where: {
        !handledBatchIDs.contains($0.batchID) && !deliveringBatchIDs.contains($0.batchID)
      })
    else {
      return
    }

    if shouldSuppressForegroundAttention(for: nextAttention, store: store) {
      handledBatchIDs.insert(nextAttention.batchID)
      if activeToast?.batchID == nextAttention.batchID {
        activeToast = nil
      }
      return
    }

    if prefersUserNotificationDelivery {
      activeToast = nil
      deliveringBatchIDs.insert(nextAttention.batchID)
      Task { @MainActor in
        defer { deliveringBatchIDs.remove(nextAttention.batchID) }
        if await notifications.deliverAcpPermissionRequest(nextAttention) {
          handledBatchIDs.insert(nextAttention.batchID)
        }
      }
      return
    }

    handledBatchIDs.insert(nextAttention.batchID)
    activeToast = nextAttention
  }

  func dismissToast() {
    activeToast = nil
  }

  func showsToast(in windowID: String) -> Bool {
    guard activeToast != nil, !prefersUserNotificationDelivery else {
      return false
    }
    switch previewContextOverride {
    case .foreground:
      if keyWindowObserver.isKey(windowID: windowID) {
        return true
      }
      return keyWindowObserver.snapshot.keyWindowIdentifier == nil
        && windowID == HarnessMonitorWindowID.main
    case .hidden:
      return false
    case nil:
      return keyWindowObserver.isKey(windowID: windowID)
    }
  }

  func routeActiveToast(
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction
  ) {
    guard let attention = activeToast else {
      return
    }
    publishRouteEvent(
      source: "toast",
      decisionID: attention.decisionID,
      batchID: attention.batchID
    )
    routeToDecision(
      decisionID: attention.decisionID,
      store: store,
      openWindow: openWindow
    )
    activeToast = nil
  }

  func routeNotificationRequestIfNeeded(
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction
  ) {
    guard notifications.decisionRequestTick != handledDecisionRequestTick,
      let decisionID = notifications.decisionRequestedID
    else {
      return
    }
    handledDecisionRequestTick = notifications.decisionRequestTick
    publishRouteEvent(
      source: "notification",
      decisionID: decisionID,
      batchID: nil
    )
    routeToDecision(
      decisionID: decisionID,
      store: store,
      openWindow: openWindow
    )
  }

  private var prefersUserNotificationDelivery: Bool {
    switch previewContextOverride {
    case .foreground:
      return false
    case .hidden:
      return true
    case nil:
      return keyWindowObserver.snapshot.prefersUserNotificationDelivery
    }
  }

  private func shouldSuppressForegroundAttention(
    for attention: AcpPermissionAttentionEvent,
    store: HarnessMonitorStore
  ) -> Bool {
    guard keyWindowObserver.isKey(windowID: HarnessMonitorWindowID.decisions),
      let selectedDecisionID = store.supervisorSelectedDecisionID
    else {
      return false
    }
    return selectedDecisionID != attention.decisionID
  }

  private func publishRouteEvent(source: String, decisionID: String, batchID: String?) {
    routeEventTick += 1
    lastRouteSource = source
    lastRouteDecisionID = decisionID
    lastRouteBatchID = batchID
  }

  private func routeToDecision(
    decisionID: String,
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction,
    activatesApp: Bool = true
  ) {
    store.supervisorSelectedDecisionID = decisionID
    store.requestPrimaryDecisionActionFocus(decisionID: decisionID)
    if activatesApp {
      Self.activateHarnessMonitorApp()
    }
    openWindow(id: HarnessMonitorWindowID.decisions)
    Task { @MainActor in
      await Self.focusDecisionsWindow()
    }
  }

  private static func activateHarnessMonitorApp() {
    if #available(macOS 14.0, *) {
      NSApplication.shared.activate()
    } else {
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
  }

  private static func decisionsWindow() -> NSWindow? {
    NSApplication.shared.windows.first { window in
      let identifier = window.identifier?.rawValue ?? ""
      return KeyWindowObserver.matchesWindowID(
        identifier, expected: HarnessMonitorWindowID.decisions)
    }
  }

  private static func focusDecisionsWindow() async {
    for _ in 0..<3 {
      await Task.yield()
      guard let window = decisionsWindow() else {
        continue
      }
      window.makeKeyAndOrderFront(nil)
      return
    }
  }

  private static func resolvePreviewContextOverride() -> PreviewContextOverride? {
    let environment = ProcessInfo.processInfo.environment
    guard
      let rawValue = environment[previewContextEnvironmentKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased(),
      !rawValue.isEmpty
    else {
      return nil
    }
    switch rawValue {
    case "foreground", "active", "live":
      return .foreground
    case "hidden", "background", "minimized":
      return .hidden
    default:
      return nil
    }
  }
}

private struct AcpPermissionAttentionSceneModifier: ViewModifier {
  let store: HarnessMonitorStore
  let notifications: HarnessMonitorUserNotificationController
  let attentionState: AcpPermissionAttentionState
  let windowID: String

  @Environment(\.openWindow)
  private var openWindow
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  private var observationKey: String {
    [
      store.pendingAcpPermissionBatches.map(\.batchId).joined(separator: "|"),
      "\(store.supervisorDecisionRefreshTick)",
      store.supervisorSelectedDecisionID ?? "nil",
      attentionState.routingToken,
    ].joined(separator: "||")
  }

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .topTrailing) {
        if attentionState.showsToast(in: windowID),
          let attention = attentionState.activeToast
        {
          AcpPermissionAttentionToastView(
            attention: attention,
            openDecisions: {
              attentionState.routeActiveToast(store: store, openWindow: openWindow)
            },
            dismiss: attentionState.dismissToast
          )
          .padding(.top, HarnessMonitorTheme.spacingSM)
          .padding(.trailing, HarnessMonitorTheme.spacingLG)
          .allowsHitTesting(true)
          .zIndex(1_000)
          .transition(AcpPermissionAttentionMotionPolicy.transition(reduceMotion: reduceMotion))
        }
      }
      .animation(
        AcpPermissionAttentionMotionPolicy.animation(reduceMotion: reduceMotion),
        value: attentionState.activeToast?.batchID
      )
      .overlay {
        if HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled {
          AccessibilityTextMarker(
            identifier: HarnessMonitorAccessibility.acpPermissionToastRouteState,
            text: attentionState.routeStateText
          )
        }
      }
      .task(id: observationKey) {
        attentionState.reconcile(store: store)
      }
      .task(id: notifications.decisionRequestTick) {
        attentionState.routeNotificationRequestIfNeeded(
          store: store,
          openWindow: openWindow
        )
      }
  }
}

enum AcpPermissionAttentionMotionPolicy {
  static func transition(reduceMotion: Bool) -> AnyTransition {
    reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
  }

  static func animation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.18)
  }

  static func markerText(reduceMotion: Bool) -> String {
    reduceMotion
      ? "transition=opacity animation=none" : "transition=move-top-opacity animation=spring"
  }
}

extension View {
  func acpPermissionAttentionScene(
    store: HarnessMonitorStore,
    notifications: HarnessMonitorUserNotificationController,
    attentionState: AcpPermissionAttentionState,
    windowID: String
  ) -> some View {
    modifier(
      AcpPermissionAttentionSceneModifier(
        store: store,
        notifications: notifications,
        attentionState: attentionState,
        windowID: windowID
      )
    )
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
