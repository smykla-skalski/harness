import HarnessMonitorKit
import SwiftUI

// Detail pane is the primary surface: identity, routing, and suggested actions
// users act on. Inspector is supplementary: context that explains the decision
// and history of prior touches. Detail content must never duplicate the
// inspector's tab content; inspector must never own primary actions.
struct SessionDecisionDetailPane: View {
  let decision: Decision
  @Bindable var runtime: SessionDecisionRuntime

  var body: some View {
    Form {
      Section("Decision") {
        LabeledContent("Summary", value: decision.summary)
        LabeledContent("Severity", value: decision.severityRaw)
        LabeledContent("Status", value: decision.statusRaw)
      }
      Section("Routing") {
        LabeledContent("Rule", value: decision.ruleID)
        if let agentID = decision.agentID {
          LabeledContent("Agent", value: agentID)
        }
        if let taskID = decision.taskID {
          LabeledContent("Task", value: taskID)
        }
      }
      if !decision.suggestedActionsJSON.isEmpty {
        Section("Suggested Actions") {
          Text(decision.suggestedActionsJSON)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
        }
      }
    }
    .formStyle(.grouped)
    .padding(24)
  }
}
