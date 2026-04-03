import HarnessMonitorKit
import SwiftUI

struct SessionContentContainer: View {
  let store: HarnessMonitorStore
  let detail: SessionDetail?
  let summary: SessionSummary?
  let timeline: [TimelineEntry]
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @State private var lastDetail: SessionDetail?
  @State private var lastTimeline: [TimelineEntry] = []

  private var activeDetail: SessionDetail? {
    detail ?? lastDetail
  }

  private var activeTimeline: [TimelineEntry] {
    detail != nil ? timeline : lastTimeline
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
        SessionsBoardView(store: store)
          .transition(.opacity)
      case .cockpit(let cockpitDetail):
        SessionCockpitView(
          detail: cockpitDetail,
          timeline: activeTimeline,
          isSessionReadOnly: store.isSessionReadOnly,
          isSessionActionInFlight: store.isSessionActionInFlight,
          isSelectionLoading: store.isSelectionLoading,
          lastAction: store.lastAction,
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
    .onChange(of: detail) { _, newDetail in
      if let newDetail {
        lastDetail = newDetail
        lastTimeline = timeline
      }
    }
    .onChange(of: summary?.sessionId) { _, newID in
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
    detail: nil,
    summary: nil,
    timeline: []
  )
  .frame(width: 980, height: 720)
}

#Preview("Session Content - Cockpit") {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded)

  SessionContentContainer(
    store: store,
    detail: store.selectedSession,
    summary: store.selectedSessionSummary,
    timeline: store.timeline
  )
  .frame(width: 980, height: 720)
}
