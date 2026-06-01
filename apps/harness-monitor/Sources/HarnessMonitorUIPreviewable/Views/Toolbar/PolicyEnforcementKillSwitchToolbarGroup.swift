import HarnessMonitorKit
import SwiftUI

public struct PolicyEnforcementKillSwitchToolbarGroup: ToolbarContent {
  private let store: HarnessMonitorStore

  public init(store: HarnessMonitorStore) {
    self.store = store
  }

  public var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      policyKillSwitchButton
    }
    .sharedBackgroundVisibility(.hidden)
  }

  private var policyWorkspace: TaskBoardPolicyCanvasWorkspace? {
    store.contentUI.dashboard.taskBoardPolicyCanvasWorkspace
  }

  private var policyEnforcementKillSwitchActive: Bool {
    policyWorkspace?.policyEnforcementKillSwitchActive ?? false
  }

  private var policyEnforcementToggleAvailable: Bool {
    if policyEnforcementKillSwitchActive {
      return true
    }
    return policyWorkspace?.canvases.contains { $0.mode != .draft } ?? false
  }

  private var policyKillSwitchButton: some View {
    Button {
      togglePolicyEnforcement()
    } label: {
      Label(
        policyEnforcementKillSwitchActive ? "Restore Policies" : "Disable Policies",
        systemImage: policyEnforcementKillSwitchActive ? "checkmark.shield" : "xmark.shield"
      )
    }
    .disabled(store.isDaemonActionInFlight || !policyEnforcementToggleAvailable)
    .help(policyKillSwitchHelpText)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasPolicyKillSwitchButton)
    .harnessMCPButton(
      HarnessMonitorAccessibility.policyCanvasPolicyKillSwitchButton,
      label: policyEnforcementKillSwitchActive ? "Restore Policies" : "Disable Policies",
      hint: policyKillSwitchHelpText,
      pressAction: togglePolicyEnforcement
    )
  }

  private var policyKillSwitchHelpText: String {
    if policyEnforcementKillSwitchActive {
      return "Restore policy enforcement to the previous canvas state"
    }
    if !policyEnforcementToggleAvailable {
      return "No enforced policies to disable"
    }
    return "Disable policy enforcement for all policy canvases"
  }

  @MainActor
  private func togglePolicyEnforcement() {
    guard policyEnforcementToggleAvailable, !store.isDaemonActionInFlight else {
      return
    }
    Task { @MainActor in
      guard await store.toggleTaskBoardPolicyCanvasEnforcement() else {
        return
      }
      syncCanvasAutomationPolicies()
    }
  }

  @MainActor
  private func syncCanvasAutomationPolicies() {
    guard let activeDocument = store.contentUI.dashboard.taskBoardPolicyPipeline else {
      return
    }
    let policyCenter = AutomationPolicyCenter.shared
    let compilation = PolicyCanvasAutomationPolicyCompiler.compileEnforcedCanvases(
      workspace: store.contentUI.dashboard.taskBoardPolicyCanvasWorkspace,
      activeDocument: activeDocument
    )
    guard !compilation.policies.isEmpty || policyCenter.document.hasCanvasPolicies else {
      return
    }
    policyCenter.replaceCanvasPolicies(compilation.policies)
  }
}
