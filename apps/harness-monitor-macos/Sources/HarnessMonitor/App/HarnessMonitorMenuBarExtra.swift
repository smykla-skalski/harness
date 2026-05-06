import AppKit
import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct HarnessMonitorMenuBarSnapshot: Equatable {
  static let statusItemTitle = "Harness Monitor"
  static let statusItemImageName = "HarnessMonitorMenuBarLighthouse"
  static let openMonitorLabel = "Open Monitor"
  static let openWorkspaceLabel = "Open Workspace"
  static let openSettingsLabel = "Settings..."
  static let refreshLabel = "Refresh"
  static let checkSupervisorLabel = "Check Supervisor Now"
  static let runWhenClosedLabel = "Run When Closed"
  static let quitLabel = "Quit Harness Monitor"

  let connectionLabel: String
  let sessionCountLabel: String
  let pendingDecisionLabel: String
  let supervisorLabel: String
  let supervisorToggleLabel: String
  let supervisorToggleDisabled: Bool

  init(
    connectionState: HarnessMonitorStore.ConnectionState,
    sessionCount: Int,
    pendingDecisionCount: Int,
    supervisorRuntimeState: HarnessMonitorStore.SupervisorRuntimeState
  ) {
    connectionLabel = "Connection: \(Self.connectionTitle(connectionState))"
    sessionCountLabel = "Sessions: \(Self.countTitle(sessionCount))"
    pendingDecisionLabel = "Decisions: \(Self.countTitle(pendingDecisionCount))"
    supervisorLabel = "Supervisor: \(Self.supervisorTitle(supervisorRuntimeState))"
    supervisorToggleLabel = Self.supervisorToggleTitle(supervisorRuntimeState)
    supervisorToggleDisabled =
      supervisorRuntimeState == .starting
      || supervisorRuntimeState == .stopping
  }

  var visibleMenuLabels: [String] {
    [
      connectionLabel,
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
}

struct HarnessMonitorMenuBarExtraLabel: View {
  let store: HarnessMonitorStore

  var body: some View {
    Label {
      Text(verbatim: HarnessMonitorMenuBarSnapshot.statusItemTitle)
    } icon: {
      Image(HarnessMonitorMenuBarSnapshot.statusItemImageName)
        .renderingMode(.template)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.menuBarExtra)
    .accessibilityLabel(HarnessMonitorMenuBarSnapshot.statusItemTitle)
    .accessibilityValue(accessibilityValue)
  }

  private var accessibilityValue: String {
    HarnessMonitorMenuBarSnapshot(
      connectionState: store.connectionState,
      sessionCount: store.sessionIndex.totalSessionCount,
      pendingDecisionCount: store.supervisorOpenDecisions.count,
      supervisorRuntimeState: store.supervisorRuntimeState
    )
    .visibleMenuLabels
    .prefix(4)
    .joined(separator: ", ")
  }
}

struct HarnessMonitorMenuBarExtraContent: View {
  let store: HarnessMonitorStore
  @Environment(\.openWindow)
  private var openWindow
  @AppStorage(SupervisorSettingsDefaults.runInBackgroundKey)
  private var runWhenClosed = SupervisorSettingsDefaults.runInBackgroundDefault

  private var snapshot: HarnessMonitorMenuBarSnapshot {
    HarnessMonitorMenuBarSnapshot(
      connectionState: store.connectionState,
      sessionCount: store.sessionIndex.totalSessionCount,
      pendingDecisionCount: store.supervisorOpenDecisions.count,
      supervisorRuntimeState: store.supervisorRuntimeState
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
    Text(verbatim: snapshot.sessionCountLabel)
      .accessibilityIdentifier(HarnessMonitorAccessibility.menuBarSessionStatus)
    Text(verbatim: snapshot.pendingDecisionLabel)
      .accessibilityIdentifier(HarnessMonitorAccessibility.menuBarDecisionStatus)
    Text(verbatim: snapshot.supervisorLabel)
      .accessibilityIdentifier(HarnessMonitorAccessibility.menuBarSupervisorStatus)
  }

  @ViewBuilder private var windowActions: some View {
    Button(HarnessMonitorMenuBarSnapshot.openMonitorLabel) {
      openAppWindow(id: HarnessMonitorWindowID.main)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.menuBarOpenMonitor)

    Button(HarnessMonitorMenuBarSnapshot.openWorkspaceLabel) {
      openAppWindow(id: HarnessMonitorWindowID.workspace)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.menuBarOpenWorkspace)

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
