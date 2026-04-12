import HarnessMonitorKit
import SwiftUI

struct SessionContentState: Equatable {
  let detail: SessionDetail?
  let summary: SessionSummary?
  let timeline: [TimelineEntry]
  let isSelectionLoading: Bool
  let isSessionReadOnly: Bool
  let isExtensionsLoading: Bool
}

struct SessionContentContainer: View {
  let store: HarnessMonitorStore
  let dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  let state: SessionContentState
  @State private var lastDetail: SessionDetail?
  @State private var lastTimeline: [TimelineEntry] = []

  private var activeDetail: SessionDetail? {
    if let detail = state.detail {
      return detail
    }
    guard lastDetail?.session.sessionId == state.summary?.sessionId else {
      return nil
    }
    return lastDetail
  }

  private var activeTimeline: [TimelineEntry] {
    state.detail != nil ? state.timeline : lastTimeline
  }

  private var mode: SessionContentMode {
    if let activeDetail {
      return .cockpit(activeDetail)
    }
    if state.isSelectionLoading, lastDetail == nil {
      return .dashboard
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
          dashboardUI: dashboardUI
        )
      case .cockpit(let cockpitDetail):
        SessionCockpitView(
          store: store,
          detail: cockpitDetail,
          timeline: activeTimeline,
          isSessionReadOnly: state.isSessionReadOnly,
          isExtensionsLoading: state.isExtensionsLoading
        )
      case .loading(let summary):
        SessionCockpitLoadingSurface(summary: summary)
      }
    }
    .onChange(of: state.detail) { _, newDetail in
      if let newDetail {
        lastDetail = newDetail
        lastTimeline = state.timeline
      }
    }
    .onChange(of: state.summary?.sessionId) { _, newID in
      if lastDetail?.session.sessionId != newID {
        lastDetail = nil
        lastTimeline = []
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
  }
}

#Preview("Session Content - Dashboard") {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded)

  SessionContentContainer(
    store: store,
    dashboardUI: store.contentUI.dashboard,
    state: .init(
      detail: nil,
      summary: nil,
      timeline: [],
      isSelectionLoading: false,
      isSessionReadOnly: false,
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
    state: .init(
      detail: store.selectedSession,
      summary: store.selectedSessionSummary,
      timeline: store.timeline,
      isSelectionLoading: false,
      isSessionReadOnly: false,
      isExtensionsLoading: false
    )
  )
  .frame(width: 980, height: 720)
}
