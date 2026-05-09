import HarnessMonitorKit
import SwiftUI

// Detail owns the decision body, routing, and suggested actions users act on.
// The inspector stays supplementary: orthogonal context and prior touches only.
struct SessionDecisionDetailPane: View {
  let decision: Decision
  @Bindable var runtime: SessionDecisionRuntime
  let filters: SessionDecisionFilterState?
  let showsFilteredNotice: Bool
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: SessionDecisionDetailPaneMetrics {
    SessionDecisionDetailPaneMetrics(fontScale: fontScale)
  }

  var body: some View {
    SessionDetailScrollSurface(contentPadding: metrics.contentPadding) {
      VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
        if showsFilteredNotice, let filters {
          SessionFilteredDecisionNotice(filters: filters)
        }
        Form {
          Section {
            LabeledContent("Summary", value: decision.summary)
            LabeledContent("Severity", value: decision.severityRaw)
            LabeledContent("Status", value: decision.statusRaw)
          } header: {
            Text("Decision")
              .harnessNativeFormSectionHeader()
          }

          Section {
            LabeledContent("Rule", value: decision.ruleID)
            if let agentID = decision.agentID {
              LabeledContent("Agent", value: agentID)
            }
            if let taskID = decision.taskID {
              LabeledContent("Task", value: taskID)
            }
          } header: {
            Text("Routing")
              .harnessNativeFormSectionHeader()
          }

          if !decision.suggestedActionsJSON.isEmpty {
            Section {
              HarnessMonitorJSONCodeBlock(
                rawJSON: decision.suggestedActionsJSON,
                chrome: .plain,
                wrapLongLines: true
              )
            } header: {
              Text("Suggested Actions")
                .harnessNativeFormSectionHeader()
            }
          }
        }
        .harnessNativeFormContainer()
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
      }
    }
    .dynamicTypeSize(.xSmall ... .accessibility5)
  }
}

struct SessionDecisionDetailPaneMetrics: Equatable {
  let contentPadding: CGFloat
  let sectionSpacing: CGFloat

  init(fontScale: CGFloat) {
    let scale = SessionWindowFontScale.metricsScale(for: fontScale)
    contentPadding = max(24, 24 * min(scale, 1.35))
    sectionSpacing = max(16, 16 * min(scale, 1.35))
  }
}
