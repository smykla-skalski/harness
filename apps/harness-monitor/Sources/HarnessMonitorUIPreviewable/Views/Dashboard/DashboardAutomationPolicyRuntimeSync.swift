import HarnessMonitorKit
import HarnessMonitorPolicyCanvas

@MainActor
enum DashboardAutomationPolicyRuntimeSynchronizer {
  static func synchronizeEnforcedCanvasAutomationPolicies(
    policyCenter: AutomationPolicyCenter,
    workspace: PolicyCanvasWorkspace?,
    activeDocument: PolicyPipelineDocument?
  ) {
    policyCenter.setKillSwitchEngaged(workspace?.spawnKillSwitch ?? false)
    let compilation = PolicyCanvasAutomationPolicyCompiler.compileEnforcedCanvases(
      workspace: workspace,
      activeDocument: activeDocument
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
