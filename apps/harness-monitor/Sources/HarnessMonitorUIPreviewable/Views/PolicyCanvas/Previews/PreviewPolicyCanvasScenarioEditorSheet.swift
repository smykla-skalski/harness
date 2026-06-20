import HarnessMonitorPolicyModels
import SwiftUI

#Preview("Scenario editor - new") {
  PolicyCanvasScenarioEditorSheet(
    request: PolicyCanvasScenarioEditRequest(
      scenarioId: nil,
      name: "",
      input: PolicyInput(action: .mergePr)
    ),
    confirm: { _, _ in },
    dismiss: {}
  )
}

#Preview("Scenario editor - edit") {
  PolicyCanvasScenarioEditorSheet(
    request: PolicyCanvasScenarioEditRequest(
      scenarioId: "s1",
      name: "Merge - checks green",
      input: PolicyInput(
        action: .mergePr,
        subject: PolicySubject(repository: "acme/app", branch: "main"),
        evidence: PolicyEvidence(
          checksGreen: true,
          reviewerVerdictApproved: true,
          riskScore: 12
        )
      )
    ),
    confirm: { _, _ in },
    dismiss: {}
  )
}
