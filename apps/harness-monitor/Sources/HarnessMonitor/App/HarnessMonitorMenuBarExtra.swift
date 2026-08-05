import AppKit
import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import Observation
import SwiftUI

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
    hasActiveWork: Bool,
    showsStateColorVariants: Bool
  ) -> String {
    if pendingDecisionCount > .zero {
      return statusItemAssetName(showsStateColorVariants: showsStateColorVariants)
    }
    return hasActiveWork
      ? HarnessMonitorMenuBarSnapshot.statusItemImageName
      : HarnessMonitorMenuBarSnapshot.statusItemIdleImageName
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
  let openPolicyWorkspace: @MainActor () -> Void
  @Environment(\.openWindow)
  private var openWindow
  @AppStorage(SupervisorSettingsDefaults.runInBackgroundKey)
  private var runWhenClosed = SupervisorSettingsDefaults.runInBackgroundDefault
  @State private var policyCenter = AutomationPolicyCenter.shared

  private var snapshot: HarnessMonitorMenuBarSnapshot {
    let toolbarSlice = store.supervisorToolbarSlice
    return HarnessMonitorMenuBarSnapshot(
      connectionState: store.connectionState,
      pendingDecisionCount: toolbarSlice.count,
      pendingDecisionSeverity: toolbarSlice.maxSeverity,
      supervisorRuntimeState: store.supervisorRuntimeState,
      activeWorkCount: store.sessionIndex.totalActiveWorkCount,
      runsWhenClosed: runWhenClosed
    )
  }

  var body: some View {
    statusSection
    Divider()
    clipboardPolicyActions
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
    Text(verbatim: snapshot.activeWorkCountLabel)
      .accessibilityIdentifier(HarnessMonitorAccessibility.menuBarSessionStatus)
    Text(verbatim: snapshot.pendingDecisionLabel)
      .accessibilityIdentifier(HarnessMonitorAccessibility.menuBarDecisionStatus)
    Text(verbatim: snapshot.supervisorLabel)
      .accessibilityIdentifier(HarnessMonitorAccessibility.menuBarSupervisorStatus)
  }

  @ViewBuilder private var clipboardPolicyActions: some View {
    Text(verbatim: policyCenter.clipboardRuntimeState.label)
      .accessibilityIdentifier("harness.menu-bar.status.clipboard-policy")

    Button("Capture Clipboard Now") {
      ClipboardAutomationCommands.captureCurrentClipboard(openWindow: openWindow)
    }
    .disabled(!policyCenter.isAutomationEnabled)

    Button("Open Policy Workspace") {
      openPolicyWorkspace()
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
  }

  @ViewBuilder private var windowActions: some View {
    Button(HarnessMonitorMenuBarSnapshot.openWorkspaceLabel) {
      openAppWindow(id: HarnessMonitorWindowID.dashboard)
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
    if id == HarnessMonitorWindowID.dashboard {
      openWindow.openHarnessDashboardWindow()
    } else {
      openWindow(id: id)
    }
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
