import HarnessMonitorKit
import HarnessMonitorPolicyCanvas
import SwiftUI

public struct GlobalPolicyEnforcementToolbarGroup: ToolbarContent {
  private let store: HarnessMonitorStore

  public init(store: HarnessMonitorStore) {
    self.store = store
  }

  public var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      globalEnforcementButton
    }
  }

  private var policyWorkspace: TaskBoardPolicyCanvasWorkspace? {
    store.contentUI.dashboard.taskBoardPolicyCanvasWorkspace
  }

  private var globalPolicyEnforcementEnabled: Bool {
    policyWorkspace?.globalPolicyEnforcementEnabled ?? true
  }

  private var globalEnforcementButton: some View {
    // Keep this plain so AppKit supplies the native toolbar platter.
    Button {
      toggleGlobalPolicyEnforcement()
    } label: {
      Label(
        globalPolicyEnforcementEnabled
          ? "Disable Global Enforcement"
          : "Enable Global Enforcement",
        systemImage: globalPolicyEnforcementEnabled ? "checkmark.shield" : "xmark.shield"
      )
    }
    .disabled(store.isDaemonActionInFlight)
    .foregroundStyle(globalPolicyEnforcementEnabled ? Color.green : Color.red)
    .help(globalEnforcementHelpText)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasGlobalEnforcementButton)
    .harnessMCPButton(
      HarnessMonitorAccessibility.policyCanvasGlobalEnforcementButton,
      label: globalPolicyEnforcementEnabled
        ? "Disable Global Enforcement"
        : "Enable Global Enforcement",
      hint: globalEnforcementHelpText,
      pressAction: toggleGlobalPolicyEnforcement
    )
  }

  private var globalEnforcementHelpText: String {
    if globalPolicyEnforcementEnabled {
      return "Global policy enforcement is enabled"
    }
    return "Global policy enforcement is disabled"
  }

  @MainActor
  private func toggleGlobalPolicyEnforcement() {
    guard !store.isDaemonActionInFlight else {
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
    let policyCenter = AutomationPolicyCenter.shared
    let compilation = PolicyCanvasAutomationPolicyCompiler.compileEnforcedCanvases(
      workspace: store.contentUI.dashboard.taskBoardPolicyCanvasWorkspace,
      activeDocument: store.contentUI.dashboard.taskBoardPolicyPipeline
    )
    let compiledPolicies = compilation.policies.map(AutomationPolicy.init)
    guard !compiledPolicies.isEmpty || policyCenter.document.hasCanvasPolicies else {
      return
    }
    policyCenter.replaceCanvasPolicies(compiledPolicies)
  }
}
