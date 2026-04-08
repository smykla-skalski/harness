import HarnessMonitorKit
import SwiftUI

struct SessionContentState: Equatable {
  let detail: SessionDetail?
  let summary: SessionSummary?
  let timeline: [TimelineEntry]
  let isSessionReadOnly: Bool
  let isSessionActionInFlight: Bool
  let isSelectionLoading: Bool
  let isExtensionsLoading: Bool
  let lastAction: String
}

struct SessionContentContainer: View {
  let store: HarnessMonitorStore
  let state: SessionContentState
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @State private var lastDetail: SessionDetail?
  @State private var lastTimeline: [TimelineEntry] = []

  private var activeDetail: SessionDetail? {
    state.detail ?? lastDetail
  }

  private var activeTimeline: [TimelineEntry] {
    state.detail != nil ? state.timeline : lastTimeline
  }

  private var mode: SessionContentMode {
    if let activeDetail {
      return .cockpit(activeDetail)
    }
    return .dashboard
  }

  private var transitionAnimation: Animation {
    reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.3)
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      switch mode {
      case .dashboard:
        SessionsBoardView(
          store: store,
          sessionIndex: store.sessionIndex,
          contentUI: store.contentUI
        )
          .transition(.opacity)
      case .cockpit(let cockpitDetail):
        SessionCockpitView(
          store: store,
          detail: cockpitDetail,
          timeline: activeTimeline,
          isSessionReadOnly: state.isSessionReadOnly,
          isSessionActionInFlight: state.isSessionActionInFlight,
          isSelectionLoading: state.isSelectionLoading,
          isExtensionsLoading: state.isExtensionsLoading,
          lastAction: state.lastAction,
          observeSelectedSession: observeSelectedSession,
          requestEndSessionConfirmation: store.requestEndSelectedSessionConfirmation,
          inspectTask: store.inspect(taskID:),
          inspectAgent: store.inspect(agentID:),
          inspectSignal: store.inspect(signalID:),
          inspectObserver: store.inspectObserver
        )
        .id(cockpitDetail.session.sessionId)
        .transition(.opacity)
      }
    }
    .animation(transitionAnimation, value: mode.identity)
    .onChange(of: state.detail) { _, newDetail in
      if let newDetail {
        lastDetail = newDetail
        lastTimeline = state.timeline
      }
    }
    .onChange(of: state.summary?.sessionId) { _, newID in
      if newID == nil {
        lastDetail = nil
        lastTimeline = []
      }
    }
  }

  private func observeSelectedSession() {
    Task {
      await store.observeSelectedSession()
    }
  }
}

private enum SessionContentMode {
  case dashboard
  case cockpit(SessionDetail)

  var identity: String {
    switch self {
    case .dashboard:
      return "dashboard"
    case .cockpit(let detail):
      return "cockpit:\(detail.session.sessionId)"
    }
  }
}

#Preview("Session Content - Dashboard") {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded)

  SessionContentContainer(
    store: store,
    state: .init(
      detail: nil,
      summary: nil,
      timeline: [],
      isSessionReadOnly: false,
      isSessionActionInFlight: false,
      isSelectionLoading: false,
      isExtensionsLoading: false,
      lastAction: ""
    )
  )
  .frame(width: 980, height: 720)
}

#Preview("Session Content - Cockpit") {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded)

  SessionContentContainer(
    store: store,
    state: .init(
      detail: store.selectedSession,
      summary: store.selectedSessionSummary,
      timeline: store.timeline,
      isSessionReadOnly: false,
      isSessionActionInFlight: false,
      isSelectionLoading: false,
      isExtensionsLoading: false,
      lastAction: ""
    )
  )
  .frame(width: 980, height: 720)
}
