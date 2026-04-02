import HarnessKit
import SwiftUI

struct SessionContentContainer: View {
  let store: HarnessStore
  let detail: SessionDetail?
  let summary: SessionSummary?
  let timeline: [TimelineEntry]

  private var mode: SessionContentMode {
    if let detail {
      return .cockpit(detail)
    }
    if let summary {
      return .loading(summary)
    }
    return .dashboard
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      SessionContentLayer(isActive: mode.isDashboard) {
        SessionsBoardView(store: store)
      }
      SessionContentLayer(isActive: mode.loadingSummary != nil) {
        if let loadingSummary = mode.loadingSummary {
          SessionLoadingView(summary: loadingSummary)
        }
      }
      SessionContentLayer(isActive: mode.detail != nil) {
        if let detail = mode.detail {
          SessionCockpitView(
            detail: detail,
            timeline: timeline,
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
        }
      }
    }
    .animation(.spring(duration: 0.3), value: mode.identity)
  }

  private func observeSelectedSession() {
    Task {
      await store.observeSelectedSession()
    }
  }
}

private enum SessionContentMode {
  case dashboard
  case loading(SessionSummary)
  case cockpit(SessionDetail)

  var identity: String {
    switch self {
    case .dashboard:
      return "dashboard"
    case .loading(let summary):
      return "loading:\(summary.sessionId)"
    case .cockpit(let detail):
      return "cockpit:\(detail.session.sessionId)"
    }
  }

  var isDashboard: Bool {
    if case .dashboard = self {
      return true
    }
    return false
  }

  var loadingSummary: SessionSummary? {
    if case .loading(let summary) = self {
      return summary
    }
    return nil
  }

  var detail: SessionDetail? {
    if case .cockpit(let detail) = self {
      return detail
    }
    return nil
  }
}

private struct SessionContentLayer<Content: View>: View {
  let isActive: Bool
  @ViewBuilder let content: Content

  var body: some View {
    content
      .opacity(isActive ? 1 : 0)
      .allowsHitTesting(isActive)
      .accessibilityHidden(!isActive)
  }
}

private struct SessionLoadingView: View {
  let summary: SessionSummary

  var body: some View {
    HarnessColumnScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
          HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
              HStack(spacing: HarnessTheme.itemSpacing) {
                Circle()
                  .fill(statusColor(for: summary.status))
                  .frame(width: 12, height: 12)
                  .accessibilityHidden(true)
                Text(summary.status.title)
                  .scaledFont(.caption.weight(.bold))
                  .foregroundStyle(statusColor(for: summary.status))
                Text(summary.context)
                  .scaledFont(.system(.largeTitle, design: .rounded, weight: .black))
                  .lineLimit(2)
              }
              Text("\(summary.projectName) • \(summary.sessionId)")
                .scaledFont(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(HarnessTheme.secondaryInk)
            }
            Spacer()
          }

          HarnessLoadingStateView(title: "Loading live session detail")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .foregroundStyle(HarnessTheme.ink)
  }
}
