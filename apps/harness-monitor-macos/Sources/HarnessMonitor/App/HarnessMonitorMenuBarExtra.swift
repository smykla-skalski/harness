import AppKit
import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import Observation
import SwiftUI

struct HarnessMonitorMenuBarSnapshot: Equatable {
  static let statusItemTitle = "Harness Monitor"
  static let statusItemImageName = "HarnessMonitorMenuBarLighthouse"
  static let statusItemInfoImageName = "HarnessMonitorMenuBarLighthouseInfo"
  static let statusItemIdleImageName = statusItemInfoImageName
  static let statusItemWarningImageName = "HarnessMonitorMenuBarLighthouseWarning"
  static let statusItemCriticalImageName = "HarnessMonitorMenuBarLighthouseCritical"
  static let openMonitorLabel = "Open Monitor"
  static let openWorkspaceLabel = "Open Recent Session"
  static let openSettingsLabel = "Settings..."
  static let refreshLabel = "Refresh"
  static let checkSupervisorLabel = "Check Supervisor Now"
  static let runWhenClosedLabel = "Run When Closed"
  static let quitLabel = "Quit Harness Monitor"
  static let activeMonitoringLabel = "Monitoring: Active session"
  static let idleMonitoringLabel = "Monitoring: No active session"
  static let activeStatusItemHelp = "Monitoring active sessions"
  static let idleStatusItemHelp = "No active session - open one to monitor"

  let pendingDecisionCount: Int
  let pendingDecisionSeverity: DecisionSeverity?
  let isMonitoringIdle: Bool
  let connectionLabel: String
  let monitoringLabel: String
  let sessionCountLabel: String
  let pendingDecisionLabel: String
  let supervisorLabel: String
  let supervisorToggleLabel: String
  let supervisorToggleDisabled: Bool

  init(
    connectionState: HarnessMonitorStore.ConnectionState,
    sessionCount: Int,
    pendingDecisionCount: Int,
    pendingDecisionSeverity: DecisionSeverity?,
    supervisorRuntimeState: HarnessMonitorStore.SupervisorRuntimeState,
    activeSessionWindowCount: Int,
    runsWhenClosed: Bool
  ) {
    self.pendingDecisionCount = pendingDecisionCount
    self.pendingDecisionSeverity = pendingDecisionSeverity
    isMonitoringIdle = activeSessionWindowCount <= 0
    connectionLabel = "Connection: \(Self.connectionTitle(connectionState))"
    monitoringLabel =
      isMonitoringIdle
      ? Self.idleMonitoringLabel
      : Self.activeMonitoringLabel
    sessionCountLabel = "Sessions: \(Self.countTitle(sessionCount))"
    pendingDecisionLabel = "Decisions: \(Self.countTitle(pendingDecisionCount))"
    supervisorLabel = Self.supervisorLabel(
      supervisorRuntimeState,
      activeSessionWindowCount: activeSessionWindowCount,
      runsWhenClosed: runsWhenClosed
    )
    supervisorToggleLabel = Self.supervisorToggleTitle(supervisorRuntimeState)
    supervisorToggleDisabled =
      supervisorRuntimeState == .starting
      || supervisorRuntimeState == .stopping
  }

  var showsAttentionBadge: Bool {
    !isMonitoringIdle && pendingDecisionCount > .zero
  }

  var attentionBadgeTintLabel: String {
    SessionAttentionBadgeStyle.tintLabel(for: pendingDecisionSeverity)
  }

  var attentionBadgeAccessibilityLabel: String {
    guard showsAttentionBadge else {
      return "Attention badge: hidden"
    }
    return "Attention badge: \(attentionBadgeTintLabel)"
  }

  var statusItemAccessibilitySummary: String {
    let idleStatus = isMonitoringIdle ? [Self.idleStatusItemHelp] : []
    return (Array(visibleMenuLabels.prefix(4)) + idleStatus + [attentionBadgeAccessibilityLabel])
      .joined(separator: ", ")
  }

  var statusItemHelpText: String {
    isMonitoringIdle ? Self.idleStatusItemHelp : Self.activeStatusItemHelp
  }

  var statusItemDisplayTitle: String {
    guard showsAttentionBadge else {
      return Self.statusItemTitle
    }
    let decisionNoun = pendingDecisionCount == 1 ? "decision" : "decisions"
    return "\(Self.statusItemTitle): \(Self.countTitle(pendingDecisionCount)) \(decisionNoun)"
  }

  var statusItemAssetName: String {
    guard !isMonitoringIdle else {
      return Self.statusItemIdleImageName
    }
    guard showsAttentionBadge else {
      return Self.statusItemImageName
    }
    switch pendingDecisionSeverity {
    case .critical:
      return Self.statusItemCriticalImageName
    case .warn, .needsUser:
      return Self.statusItemWarningImageName
    case .none, .info:
      return Self.statusItemInfoImageName
    }
  }

  var visibleMenuLabels: [String] {
    [
      connectionLabel,
      monitoringLabel,
      sessionCountLabel,
      pendingDecisionLabel,
      supervisorLabel,
      Self.openMonitorLabel,
      Self.openWorkspaceLabel,
      Self.openSettingsLabel,
      Self.refreshLabel,
      supervisorToggleLabel,
      Self.checkSupervisorLabel,
      Self.runWhenClosedLabel,
      Self.quitLabel,
    ]
  }

  private static func connectionTitle(
    _ state: HarnessMonitorStore.ConnectionState
  ) -> String {
    switch state {
    case .idle:
      "Idle"
    case .connecting:
      "Connecting"
    case .online:
      "Online"
    case .offline:
      "Offline"
    }
  }

  private static func supervisorTitle(
    _ state: HarnessMonitorStore.SupervisorRuntimeState
  ) -> String {
    switch state {
    case .stopped:
      "Stopped"
    case .starting:
      "Starting"
    case .running:
      "Running"
    case .stopping:
      "Stopping"
    }
  }

  private static func supervisorLabel(
    _ state: HarnessMonitorStore.SupervisorRuntimeState,
    activeSessionWindowCount: Int,
    runsWhenClosed: Bool
  ) -> String {
    if activeSessionWindowCount == 0 && state == .running && runsWhenClosed {
      return "Supervisor: Running in background"
    }
    return "Supervisor: \(supervisorTitle(state))"
  }

  private static func supervisorToggleTitle(
    _ state: HarnessMonitorStore.SupervisorRuntimeState
  ) -> String {
    switch state {
    case .stopped, .stopping:
      "Enable Supervisor"
    case .starting, .running:
      "Disable Supervisor"
    }
  }

  private static func countTitle(_ count: Int) -> String {
    switch count {
    case ..<0:
      "0"
    case 0...999:
      String(count)
    default:
      "999+"
    }
  }

  static func statusItemHelpText(activeSessionWindowCount: Int) -> String {
    activeSessionWindowCount <= 0 ? idleStatusItemHelp : activeStatusItemHelp
  }

  static func statusItemAccessibilityLabel(activeSessionWindowCount: Int) -> String {
    guard activeSessionWindowCount <= 0 else {
      return statusItemTitle
    }
    return "\(statusItemTitle): \(idleStatusItemHelp)"
  }
}

struct HarnessMonitorMenuBarStatusPresentation: Equatable {
  static let idle = Self(pendingDecisionCount: 0, pendingDecisionSeverity: nil)

  let pendingDecisionCount: Int
  let pendingDecisionSeverity: DecisionSeverity?

  func statusItemAssetName(showsStateColorVariants: Bool) -> String {
    guard showsStateColorVariants, pendingDecisionCount > .zero else {
      return HarnessMonitorMenuBarSnapshot.statusItemImageName
    }
    switch pendingDecisionSeverity {
    case .critical:
      return HarnessMonitorMenuBarSnapshot.statusItemCriticalImageName
    case .warn, .needsUser:
      return HarnessMonitorMenuBarSnapshot.statusItemWarningImageName
    case .none, .info:
      return HarnessMonitorMenuBarSnapshot.statusItemInfoImageName
    }
  }

  func statusItemAssetName(
    activeSessionWindowCount: Int,
    showsStateColorVariants: Bool
  ) -> String {
    guard activeSessionWindowCount > 0 else {
      return HarnessMonitorMenuBarSnapshot.statusItemIdleImageName
    }
    return statusItemAssetName(showsStateColorVariants: showsStateColorVariants)
  }

  var statusItemAssetName: String {
    statusItemAssetName(showsStateColorVariants: true)
  }
}

@MainActor
@Observable
final class HarnessMonitorMenuBarStatusController {
  private(set) var presentation = HarnessMonitorMenuBarStatusPresentation.idle
  @ObservationIgnored private var updateTask: Task<Void, Never>?

  func schedule(pendingDecisionCount: Int, pendingDecisionSeverity: DecisionSeverity?) {
    let next = HarnessMonitorMenuBarStatusPresentation(
      pendingDecisionCount: pendingDecisionCount,
      pendingDecisionSeverity: pendingDecisionSeverity
    )
    guard next != presentation else {
      return
    }
    updateTask?.cancel()
    updateTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled else {
        return
      }
      self?.presentation = next
    }
  }

  func reset() {
    updateTask?.cancel()
    updateTask = nil
    presentation = .idle
  }
}

struct HarnessMonitorMenuBarExtraContent: View {
  let store: HarnessMonitorStore
  let activeSessionWindowCount: Int
  @Environment(\.openWindow)
  private var openWindow
  @AppStorage(SupervisorSettingsDefaults.runInBackgroundKey)
  private var runWhenClosed = SupervisorSettingsDefaults.runInBackgroundDefault

  private var snapshot: HarnessMonitorMenuBarSnapshot {
    let toolbarSlice = store.supervisorToolbarSlice
    return HarnessMonitorMenuBarSnapshot(
      connectionState: store.connectionState,
      sessionCount: store.sessionIndex.totalSessionCount,
      pendingDecisionCount: toolbarSlice.count,
      pendingDecisionSeverity: toolbarSlice.maxSeverity,
      supervisorRuntimeState: store.supervisorRuntimeState,
      activeSessionWindowCount: activeSessionWindowCount,
      runsWhenClosed: runWhenClosed
    )
  }

  var body: some View {
    statusSection
    Divider()
    windowActions
    Divider()
    supervisorActions
    Divider()
    Button(HarnessMonitorMenuBarSnapshot.quitLabel) {
      NSApplication.shared.terminate(nil)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.menuBarQuit)
  }

  @ViewBuilder private var statusSection: some View {
    Text(verbatim: snapshot.connectionLabel)
      .accessibilityIdentifier(HarnessMonitorAccessibility.menuBarConnectionStatus)
    Text(verbatim: snapshot.monitoringLabel)
      .accessibilityIdentifier("harness.menu-bar.monitoring-status")
    Text(verbatim: snapshot.sessionCountLabel)
      .accessibilityIdentifier(HarnessMonitorAccessibility.menuBarSessionStatus)
    Text(verbatim: snapshot.pendingDecisionLabel)
      .accessibilityIdentifier(HarnessMonitorAccessibility.menuBarDecisionStatus)
    Text(verbatim: snapshot.supervisorLabel)
      .accessibilityIdentifier(HarnessMonitorAccessibility.menuBarSupervisorStatus)
  }

  @ViewBuilder private var windowActions: some View {
    Button(HarnessMonitorMenuBarSnapshot.openMonitorLabel) {
      openAppWindow(id: HarnessMonitorWindowID.openRecent)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.menuBarOpenMonitor)

    Button(HarnessMonitorMenuBarSnapshot.openWorkspaceLabel) {
      openAppWindow(id: HarnessMonitorWindowID.openRecent)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.menuBarOpenSession)

    Button(HarnessMonitorMenuBarSnapshot.openSettingsLabel) {
      openAppWindow(id: HarnessMonitorWindowID.settings)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.menuBarOpenSettings)

    Button(HarnessMonitorMenuBarSnapshot.refreshLabel) {
      Task { await store.refresh() }
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.menuBarRefresh)
  }

  @ViewBuilder private var supervisorActions: some View {
    Button(snapshot.supervisorToggleLabel) {
      toggleSupervisor()
    }
    .disabled(snapshot.supervisorToggleDisabled)
    .accessibilityIdentifier(HarnessMonitorAccessibility.menuBarSupervisorToggle)

    Button(HarnessMonitorMenuBarSnapshot.checkSupervisorLabel) {
      Task { await store.requestSupervisorCheckNow() }
    }
    .disabled(!store.canRequestSupervisorCheckNow)
    .accessibilityIdentifier(HarnessMonitorAccessibility.menuBarSupervisorCheckNow)

    Toggle(
      HarnessMonitorMenuBarSnapshot.runWhenClosedLabel,
      isOn: Binding(
        get: { runWhenClosed },
        set: { enabled in
          runWhenClosed = enabled
          store.setSupervisorRunInBackgroundEnabled(enabled)
        }
      )
    )
    .accessibilityIdentifier(HarnessMonitorAccessibility.menuBarRunWhenClosed)
  }

  private func openAppWindow(id: String) {
    openWindow(id: id)
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  private func toggleSupervisor() {
    Task {
      switch store.supervisorRuntimeState {
      case .stopped, .stopping:
        await store.startSupervisor()
      case .starting, .running:
        await store.stopSupervisor()
      }
    }
  }
}
