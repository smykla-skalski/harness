import HarnessMonitorKit
import SwiftUI

// Detail owns the decision body, routing, and suggested actions users act on.
// The inspector stays supplementary: orthogonal context and prior touches only.
struct SessionDecisionDetailPane: View {
  let decision: Decision
  @Bindable var runtime: SessionDecisionRuntime
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: SessionDecisionDetailPaneMetrics {
    SessionDecisionDetailPaneMetrics(fontScale: fontScale)
  }

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
          HarnessMonitorJSONCodeBlock(
            rawJSON: decision.suggestedActionsJSON,
            chrome: .plain,
            wrapLongLines: true
          )
        }
      }
    }
    .formStyle(.grouped)
    .padding(metrics.contentPadding)
  }
}

struct SessionDecisionDetailPaneMetrics: Equatable {
  let contentPadding: CGFloat

  init(fontScale: CGFloat) {
    let scale = SessionWindowFontScale.metricsScale(for: fontScale)
    contentPadding = max(24, 24 * min(scale, 1.35))
  }
}
