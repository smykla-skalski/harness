import HarnessMonitorKit
import SwiftUI

// Detail owns the decision body, routing, and suggested actions users act on.
// The inspector stays supplementary: orthogonal context and prior touches only.
struct SessionDecisionDetailPane: View {
  let decision: Decision?
  let store: HarnessMonitorStore
  let auditEvents: [SupervisorEventSnapshot]
  let auditEventPayloadPresentations: [String: DecisionAuditTrailPayloadPresentation]
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

  // Cache the @Observable view model across parent body invocations. Without
  // this the view model would be reconstructed on every body call, which
  // would (a) replace the deeplinks array reference and thrash the ForEach
  // evictor (191 incoming edges in the post-fix trace), and (b) defeat the
  // fine-grained property tracking @Observable is supposed to provide.
  @State private var cachedViewModel: DecisionDetailViewModel?

  var body: some View {
    VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
      if showsFilteredNotice, let filters {
        SessionFilteredDecisionNotice(filters: filters)
          .padding(.top, metrics.contentPadding)
          .padding(.horizontal, metrics.contentPadding)
      }
      // Optional viewModel keeps the SwiftUI tree identity stable when
      // decision flips between nil and non-nil; two separate call sites
      // previously produced `_ConditionalContent<DecisionDetailView,
      // DecisionDetailView>` and tore down @FocusState on every flip.
      DecisionDetailView(
        viewModel: cachedViewModel,
        store: store,
        auditEvents: auditEvents,
        auditEventPayloadPresentations: auditEventPayloadPresentations,
        selectedTab: $selectedTab,
        observer: observer,
        decisionScope: decisionScope,
        primaryActionFocusDecisionID: store.supervisorPrimaryActionFocusDecisionID,
        primaryActionFocusRequestTick: store.supervisorPrimaryActionFocusRequestTick
      )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .dynamicTypeSize(.xSmall ... .accessibility5)
    .task(id: decision?.id) {
      syncCachedViewModel()
    }
  }

  private func syncCachedViewModel() {
    guard let decision else {
      if cachedViewModel != nil {
        cachedViewModel = nil
      }
      return
    }
    if cachedViewModel?.decision.id != decision.id {
      cachedViewModel = DecisionDetailViewModel(
        decision: decision,
        handler: actionHandler
      )
    }
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
