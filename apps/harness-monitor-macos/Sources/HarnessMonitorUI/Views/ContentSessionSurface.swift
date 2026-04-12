import HarnessMonitorKit
import SwiftUI

struct SessionContentState: Equatable {
  let detail: SessionDetail?
  let summary: SessionSummary?
  let timeline: [TimelineEntry]
  let isSessionReadOnly: Bool
  let isExtensionsLoading: Bool
}

struct SessionContentPresentation: Equatable {
  let mode: SessionContentMode
  let activeTimeline: [TimelineEntry]

  init(
    state: SessionContentState,
    lastDetail: SessionDetail?,
    lastTimeline: [TimelineEntry]
  ) {
    let activeDetail: SessionDetail? = if let detail = state.detail {
      detail
    } else if lastDetail?.session.sessionId == state.summary?.sessionId {
      lastDetail
    } else {
      nil
    }

    activeTimeline = state.detail != nil ? state.timeline : lastTimeline
    if let activeDetail {
      mode = .cockpit(activeDetail)
    } else {
      // Keep the dashboard stable until live detail is available so the first
      // selection does not force a dashboard -> loading -> cockpit swap.
      mode = .dashboard
    }
  }
}

struct SessionContentContainer: View {
  let store: HarnessMonitorStore
  let dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  let state: SessionContentState
  @State private var lastDetail: SessionDetail?
  @State private var lastTimeline: [TimelineEntry] = []

  private var presentation: SessionContentPresentation {
    SessionContentPresentation(
      state: state,
      lastDetail: lastDetail,
      lastTimeline: lastTimeline
    )
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      switch presentation.mode {
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
          timeline: presentation.activeTimeline,
          isSessionReadOnly: state.isSessionReadOnly,
          isExtensionsLoading: state.isExtensionsLoading
        )
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

enum SessionContentMode: Equatable {
  case dashboard
  case cockpit(SessionDetail)
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
      isSessionReadOnly: false,
      isExtensionsLoading: false
    )
  )
  .frame(width: 980, height: 720)
}
