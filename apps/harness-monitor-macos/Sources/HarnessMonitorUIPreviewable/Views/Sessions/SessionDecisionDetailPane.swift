import HarnessMonitorKit
import SwiftUI

// Detail owns the decision body, routing, and suggested actions users act on.
// The inspector stays supplementary: orthogonal context and prior touches only.
struct SessionDecisionDetailPane: View {
  let decision: Decision?
  let store: HarnessMonitorStore
  let auditEvents: [SupervisorEvent]
  let observer: ObserverSummary?
  let decisionScope: DecisionWorkspaceScope
  @Binding var selectedTab: DecisionDetailTab
  let filters: SessionDecisionFilterState?
  let showsFilteredNotice: Bool
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: SessionDecisionDetailPaneMetrics {
    SessionDecisionDetailPaneMetrics(fontScale: fontScale)
  }

  private var actionHandler: any DecisionActionHandler {
    store.supervisorDecisionActionHandler()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
      if showsFilteredNotice, let filters {
        SessionFilteredDecisionNotice(filters: filters)
          .padding(.top, metrics.contentPadding)
          .padding(.horizontal, metrics.contentPadding)
      }
      if let decision {
        DecisionDetailView(
          decision: decision,
          store: store,
          handler: actionHandler,
          auditEvents: auditEvents,
          selectedTab: $selectedTab,
          observer: observer,
          decisionScope: decisionScope,
          primaryActionFocusDecisionID: store.supervisorPrimaryActionFocusDecisionID,
          primaryActionFocusRequestTick: store.supervisorPrimaryActionFocusRequestTick
        )
      } else {
        DecisionDetailView(
          selectedTab: $selectedTab,
          observer: observer,
          decisionScope: decisionScope,
          primaryActionFocusDecisionID: store.supervisorPrimaryActionFocusDecisionID,
          primaryActionFocusRequestTick: store.supervisorPrimaryActionFocusRequestTick
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
