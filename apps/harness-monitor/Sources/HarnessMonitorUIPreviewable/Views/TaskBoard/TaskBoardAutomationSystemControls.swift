import HarnessMonitorKit
import SwiftUI

struct TaskBoardAutomationSystemControls: View {
  let store: HarnessMonitorStore
  let state: TaskBoardAutomationInspectorState
  let presentation: TaskBoardAutomationPresentation
  let metrics: TaskBoardOverviewMetrics
  let isPresentationCurrent: Bool
  let actions: TaskBoardAutomationInspectorActions

  var body: some View {
    TaskBoardOperationsCard(
      title: "Automation systems",
      metrics: metrics,
      footer: footerText
    ) {
      systemToggle(
        SystemToggleConfiguration(
          title: "Task Board processing",
          subtitle: processingSubtitle,
          help: processingBlockedReason ?? "Enable continuous task-board processing",
          accessibilityIdentifier: "harness.task-board.automation.system.processing"
        ),
        isOn: processingBinding,
        isPending: state.activeAction == .start || state.activeAction == .stop,
        isDisabled: processingBlockedReason != nil
      )
      Divider()
      systemToggle(
        SystemToggleConfiguration(
          title: "Automatic triage",
          subtitle: triageSubtitle,
          help: triageHelpText,
          accessibilityIdentifier: "harness.task-board.automation.system.triage"
        ),
        isOn: triageBinding,
        isPending: state.pendingTriageAutomationEnabled != nil,
        isDisabled: !isOnline || orchestratorSettings == nil
      )
      Divider()
      systemToggle(
        SystemToggleConfiguration(
          title: "Policy automation",
          subtitle: policySubtitle,
          help: policyHelpText,
          accessibilityIdentifier: "harness.task-board.automation.system.policy"
        ),
        isOn: policyBinding,
        isPending: state.pendingPolicyAutomationEnabled != nil,
        isDisabled: !isOnline || policyWorkspace == nil
      )
    }
  }

  private var footerText: String {
    killSwitchEngaged
      ? Self.engagedFooterText
      : "The App Kill Switch in the toolbar overrides every automation system"
  }

  private static let engagedFooterText =
    "Task Board processing stays stopped after release; "
    + "enabled systems remain paused while the kill switch is engaged"

  private var triageHelpText: String {
    isOnline && orchestratorSettings != nil
      ? "Classify incoming tasks and request agent triage when rules need help"
      : "Automatic triage state is not available"
  }

  private var policyHelpText: String {
    policyWorkspace == nil
      ? "Policy automation state is not available"
      : "Apply enabled policy canvases to supported app actions"
  }

  private var processingBinding: Binding<Bool> {
    Binding(
      get: {
        switch state.activeAction {
        case .start: true
        case .stop: false
        default: processingEnabled
        }
      },
      set: { enabled in
        guard enabled != processingEnabled else { return }
        actions.enqueueControl(
          enabled ? .start : .stop,
          isPresentationCurrent: isPresentationCurrent,
          controlBlockedReason: enabled
            ? presentation.controlAvailability.controlBlockedReason
            : presentation.controlAvailability.stopBlockedReason
        )
      }
    )
  }

  private var triageBinding: Binding<Bool> {
    Binding(
      get: {
        state.pendingTriageAutomationEnabled
          ?? orchestratorSettings?.triageAutomationEnabled
          ?? false
      },
      set: { actions.enqueueTriageAutomation(enabled: $0) }
    )
  }

  private var policyBinding: Binding<Bool> {
    Binding(
      get: {
        state.pendingPolicyAutomationEnabled
          ?? policyWorkspace?.globalPolicyEnforcementEnabled
          ?? false
      },
      set: { actions.enqueuePolicyAutomation(enabled: $0) }
    )
  }

  private var processingEnabled: Bool {
    store.contentUI.dashboard.taskBoardOrchestratorStatus?.enabled ?? false
  }

  private var processingBlockedReason: String? {
    guard isPresentationCurrent else { return "Automation status is updating" }
    if killSwitchEngaged {
      return "Disengage the app kill switch before starting Task Board processing"
    }
    return processingEnabled
      ? presentation.controlAvailability.stopBlockedReason
      : presentation.controlAvailability.controlBlockedReason
  }

  private var processingSubtitle: String {
    statusSubtitle(configuredEnabled: processingEnabled, active: processingRunning)
  }

  private var triageSubtitle: String {
    guard let orchestratorSettings else { return "Unavailable" }
    return statusSubtitle(
      configuredEnabled: orchestratorSettings.triageAutomationEnabled,
      active: true
    )
  }

  private var policySubtitle: String {
    guard let policyWorkspace else { return "Unavailable" }
    return statusSubtitle(
      configuredEnabled: policyWorkspace.globalPolicyEnforcementEnabled,
      active: true
    )
  }

  private func statusSubtitle(configuredEnabled: Bool, active: Bool) -> String {
    guard configuredEnabled else { return "Disabled" }
    if killSwitchEngaged { return "Enabled, paused by kill switch" }
    return active ? "Enabled" : "Enabled, waiting"
  }

  private var processingRunning: Bool {
    store.contentUI.dashboard.taskBoardOrchestratorStatus?.running ?? false
  }

  private var killSwitchEngaged: Bool {
    policyWorkspace?.spawnKillSwitch ?? false
  }

  private var isOnline: Bool {
    store.contentUI.dashboard.connectionState == .online
  }

  private var orchestratorSettings: TaskBoardOrchestratorSettings? {
    store.contentUI.dashboard.taskBoardOrchestratorStatus?.settings
  }

  private var policyWorkspace: PolicyCanvasWorkspace? {
    store.contentUI.dashboard.policyCanvasWorkspace
  }

  private func systemToggle(
    _ configuration: SystemToggleConfiguration,
    isOn: Binding<Bool>,
    isPending: Bool,
    isDisabled: Bool
  ) -> some View {
    HStack(spacing: HarnessMonitorTheme.spacingMD) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Text(configuration.title)
          .scaledFont(.body.weight(.medium))
        Text(configuration.subtitle)
          .scaledFont(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if isPending {
        ProgressView()
          .controlSize(.small)
          .accessibilityHidden(true)
      }
      Toggle("", isOn: isOn)
        .toggleStyle(.switch)
        .labelsHidden()
        .controlSize(.mini)
        .disabled(isDisabled || isPending)
        .help(configuration.help)
        .accessibilityLabel(configuration.title)
        .accessibilityValue(configuration.subtitle)
        .accessibilityIdentifier(configuration.accessibilityIdentifier)
    }
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
  }
}

private struct SystemToggleConfiguration {
  let title: String
  let subtitle: String
  let help: String
  let accessibilityIdentifier: String
}
