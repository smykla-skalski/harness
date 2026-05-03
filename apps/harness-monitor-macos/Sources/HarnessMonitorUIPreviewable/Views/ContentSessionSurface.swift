import HarnessMonitorKit
import SwiftUI

struct SessionContentState {
  let detail: SessionDetail?
  let summary: SessionSummary?
  let timeline: [TimelineEntry]
  let timelineWindow: TimelineWindowResponse?
  let tuiStatusByAgent: [String: AgentTuiStatus]
  let isSessionStatusStale: Bool
  let isSessionReadOnly: Bool
  let isSelectionLoading: Bool
  let isTimelineLoading: Bool
  let isExtensionsLoading: Bool
}

public enum SessionContentPrimaryFocusTarget: String {
  case dashboard
  case cockpit
  case loading
}

struct SessionContentContainer: View {
  let store: HarnessMonitorStore
  let dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  let primaryContentFocusScope: Namespace.ID?
  let primaryContentPagingResponderRequest: Int
  let primaryContentFocusTarget: SessionContentPrimaryFocusTarget
  let state: SessionContentState

  private var mode: SessionContentMode {
    if let detail = state.detail {
      return .cockpit(detail)
    }
    if let summary = state.summary {
      return .loading(summary)
    }
    return .dashboard
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      switch mode {
      case .dashboard:
        SessionsBoardView(
          store: store,
          sessionCatalog: store.sessionIndex.catalog,
          dashboardUI: dashboardUI,
          primaryContentFocusScope: primaryContentFocusScope,
          primaryContentPagingResponderRequest: primaryContentPagingResponderRequest,
          prefersPrimaryContentFocus: primaryContentFocusTarget == .dashboard
        )
      case .cockpit(let cockpitDetail):
        SessionCockpitView(
          store: store,
          detail: cockpitDetail,
          timeline: state.timeline,
          timelineWindow: state.timelineWindow,
          tuiStatusByAgent: state.tuiStatusByAgent,
          isSessionStatusStale: state.isSessionStatusStale,
          isSessionReadOnly: state.isSessionReadOnly,
          isTimelineLoading: state.isTimelineLoading,
          isExtensionsLoading: state.isExtensionsLoading,
          primaryContentFocusScope: primaryContentFocusScope,
          primaryContentPagingResponderRequest: primaryContentPagingResponderRequest,
          prefersPrimaryContentFocus: primaryContentFocusTarget == .cockpit
        )
      case .loading(let summary):
        SessionCockpitLoadingSurface(
          summary: summary,
          primaryContentFocusScope: primaryContentFocusScope,
          primaryContentPagingResponderRequest: primaryContentPagingResponderRequest,
          prefersPrimaryContentFocus: primaryContentFocusTarget == .loading
        )
      }
    }
  }

}

private enum SessionContentMode {
  case dashboard
  case cockpit(SessionDetail)
  case loading(SessionSummary)
}

private struct SessionCockpitLoadingSurface: View {
  let summary: SessionSummary
  let primaryContentFocusScope: Namespace.ID?
  let primaryContentPagingResponderRequest: Int
  let prefersPrimaryContentFocus: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      Label(summary.displayTitle, systemImage: "arrow.trianglehead.2.clockwise")
        .font(.system(.title3, design: .rounded, weight: .semibold))
      Text("Loading session details")
        .font(.callout)
        .foregroundStyle(.secondary)
      ProgressView()
        .controlSize(.small)
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Loading \(summary.displayTitle)")
    .harnessPrimaryContentFocusTarget(
      focusScope: primaryContentFocusScope,
      prefersDefaultFocus: prefersPrimaryContentFocus,
      pagingResponderRequest: primaryContentPagingResponderRequest
    )
  }
}

#Preview("Session Content - Dashboard") {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded)

  SessionContentContainer(
    store: store,
    dashboardUI: store.contentUI.dashboard,
    primaryContentFocusScope: nil,
    primaryContentPagingResponderRequest: 0,
    primaryContentFocusTarget: .dashboard,
    state: .init(
      detail: nil,
      summary: nil,
      timeline: [],
      timelineWindow: nil,
      tuiStatusByAgent: [:],
      isSessionStatusStale: false,
      isSessionReadOnly: false,
      isSelectionLoading: false,
      isTimelineLoading: false,
      isExtensionsLoading: false
    )
  )
  .frame(width: 980, height: 720)
}

#Preview("Session Content - Cockpit") {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded)

  SessionContentContainer(
    store: store,
    dashboardUI: store.contentUI.dashboard,
    primaryContentFocusScope: nil,
    primaryContentPagingResponderRequest: 0,
    primaryContentFocusTarget: .cockpit,
    state: .init(
      detail: store.selectedSession,
      summary: store.selectedSessionSummary,
      timeline: store.timeline,
      timelineWindow: store.timelineWindow,
      tuiStatusByAgent: [:],
      isSessionStatusStale: false,
      isSessionReadOnly: false,
      isSelectionLoading: false,
      isTimelineLoading: false,
      isExtensionsLoading: false
    )
  )
  .frame(width: 980, height: 720)
}
