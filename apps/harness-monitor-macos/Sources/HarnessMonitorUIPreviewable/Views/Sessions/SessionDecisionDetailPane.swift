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
        SessionDetailPanel(title: "Decision") {
          SessionDetailFactsGrid(facts: summaryFacts)
        }
        SessionDetailPanel(title: "Routing") {
          SessionDetailFactsGrid(facts: routingFacts)
        }
        if !decision.suggestedActionsJSON.isEmpty {
          SessionDetailPanel(title: "Suggested Actions") {
            HarnessMonitorJSONCodeBlock(
              rawJSON: decision.suggestedActionsJSON,
              chrome: .plain,
              wrapLongLines: true
            )
          }
        }
      }
    }
    .dynamicTypeSize(.xSmall ... .accessibility5)
  }

  private var summaryFacts: [SessionDetailFact] {
    [
      .init("Summary", value: decision.summary),
      .init("Severity", value: decision.severityRaw),
      .init("Status", value: decision.statusRaw),
    ]
  }

  private var routingFacts: [SessionDetailFact] {
    var facts: [SessionDetailFact] = [
      .init("Rule", value: decision.ruleID)
    ]
    if let agentID = decision.agentID {
      facts.append(.init("Agent", value: agentID))
    }
    if let taskID = decision.taskID {
      facts.append(.init("Task", value: taskID))
    }
    return facts
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
