import HarnessMonitorKit
import HarnessMonitorPolicyCanvas

@MainActor
enum DashboardAutomationPolicyRuntimeSynchronizer {
  static func synchronizeEnforcedCanvasAutomationPolicies(
    policyCenter: AutomationPolicyCenter,
    workspace: PolicyCanvasWorkspace?,
    activeDocument: PolicyPipelineDocument?,
    isRecovering: Bool = false
  ) {
    policyCenter.setKillSwitchEngaged(isRecovering || workspace?.spawnKillSwitch == true)
    let compilation = PolicyCanvasAutomationPolicyCompiler.compileEnforcedCanvases(
      workspace: isRecovering ? nil : workspace,
      activeDocument: isRecovering ? nil : activeDocument
    )
    let compiledPolicies = compilation.policies.map(AutomationPolicy.init)
    guard policyCenter.document.canvasPolicies != compiledPolicies else {
      return
    }
    guard !compiledPolicies.isEmpty || policyCenter.document.hasCanvasPolicies else {
      return
    }
    policyCenter.replaceCanvasPolicies(compiledPolicies)
  }
}
