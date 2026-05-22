import HarnessMonitorKit
import SwiftUI

/// POD top-of-conversation bar: refresh button + load-state hint.
/// Takes only the values it needs (`loadState`, `entriesCount`,
/// `onRefresh`) so SwiftUI can skip its body when those POD inputs
/// haven't changed — per `references/performance-patterns.md` §3
/// "Pass Only What Views Need" / §5 "POD Views for Fast Diffing".
///
/// `lastError` is intentionally NOT shown here — the composer surfaces
/// errors via `DashboardDependencyCommentRetryStrip`. This bar only
/// owns the refresh affordance + an event-count chip + the
/// transient "Refreshing…" hint.
struct DashboardDependencyConversationStatusBar: View {
  let loadState: DependencyUpdateTimelineViewModel.LoadState
  let entriesCount: Int
  let onRefresh: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      if loadState == .refreshing {
        HarnessMonitorSpinner(size: 12)
        Text("Refreshing…").font(.caption).foregroundStyle(.secondary)
      } else if entriesCount > 0 {
        Text("\(entriesCount) events")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button(action: onRefresh) {
        Label("Refresh", systemImage: "arrow.clockwise")
          .labelStyle(.iconOnly)
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
      .disabled(loadState != .idle && loadState != .failed)
      .help("Refresh conversation")
      .accessibilityLabel(Text("Refresh conversation"))
    }
  }
}

extension DashboardDependencyConversationStatusBar: @MainActor Equatable {
  static func == (
    lhs: DashboardDependencyConversationStatusBar,
    rhs: DashboardDependencyConversationStatusBar
  ) -> Bool {
    // POD comparison: closures don't participate (any onRefresh from
    // the same parent points at the same logic). SwiftUI invalidates
    // when loadState or entriesCount actually change.
    lhs.loadState == rhs.loadState && lhs.entriesCount == rhs.entriesCount
  }
}

/// POD position footer — "Showing N (more available)" / "N events" —
/// for the conversation feed's Load Older region. Takes only the two
/// scalars it needs.
struct DashboardDependencyConversationPositionFooter: View {
  let entriesCount: Int
  let hasOlder: Bool

  var body: some View {
    Group {
      if hasOlder {
        Text("Showing \(entriesCount) (more available)")
      } else {
        Text("\(entriesCount) events")
      }
    }
    .font(.caption.monospacedDigit())
    .foregroundStyle(.secondary)
    .accessibilityLabel(
      Text(
        hasOlder
          ? "Showing \(entriesCount) events, more available"
          : "Showing all \(entriesCount) events"
      )
    )
  }
}

extension DashboardDependencyConversationPositionFooter: @MainActor Equatable {
  static func == (
    lhs: DashboardDependencyConversationPositionFooter,
    rhs: DashboardDependencyConversationPositionFooter
  ) -> Bool {
    lhs.entriesCount == rhs.entriesCount && lhs.hasOlder == rhs.hasOlder
  }
}
