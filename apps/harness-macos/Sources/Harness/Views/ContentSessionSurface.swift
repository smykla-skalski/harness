import HarnessKit
import SwiftUI

struct SessionContentContainer: View {
  let store: HarnessStore
  let detail: SessionDetail?
  let summary: SessionSummary?
  let timeline: [TimelineEntry]

  var body: some View {
    Group {
      if let detail {
        SessionCockpitView(
          detail: detail,
          timeline: timeline,
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
          .transition(.opacity)
      } else if let summary {
        SessionLoadingView(summary: summary)
          .transition(.opacity)
      } else {
        SessionsBoardView(store: store)
          .transition(.opacity)
      }
    }
    .animation(.spring(duration: 0.3), value: detail?.session.sessionId)
    .animation(.spring(duration: 0.3), value: summary?.sessionId)
  }

  private func observeSelectedSession() {
    Task {
      await store.observeSelectedSession()
    }
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
