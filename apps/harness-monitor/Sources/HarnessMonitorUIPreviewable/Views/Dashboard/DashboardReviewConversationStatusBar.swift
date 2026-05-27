import HarnessMonitorKit
import SwiftUI

/// POD top-of-conversation bar: refresh button + load-state hint.
/// Takes only the values it needs (`loadState`, `countSummary`,
/// `onRefresh`) so SwiftUI can skip its body when those POD inputs
/// haven't changed — per `references/performance-patterns.md` §3
/// "Pass Only What Views Need" / §5 "POD Views for Fast Diffing".
///
/// `lastError` is intentionally NOT shown here — the composer surfaces
/// errors via `DashboardReviewCommentRetryStrip`. This bar only
/// owns the refresh affordance + an event-count chip + the
/// transient "Refreshing…" hint.
struct DashboardReviewConversationStatusBar: View {
  let loadState: ReviewTimelineViewModel.LoadState
  let countSummary: DashboardReviewConversationCountSummary
  let fontScale: CGFloat
  let onRefresh: () -> Void
  let captionFont: Font
  let captionMonospacedFont: Font

  init(
    loadState: ReviewTimelineViewModel.LoadState,
    countSummary: DashboardReviewConversationCountSummary,
    fontScale: CGFloat,
    onRefresh: @escaping () -> Void
  ) {
    self.loadState = loadState
    self.countSummary = countSummary
    self.fontScale = fontScale
    self.onRefresh = onRefresh
    captionFont = HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
    captionMonospacedFont = HarnessMonitorTextSize.scaledFont(
      .caption.monospacedDigit(),
      by: fontScale
    )
  }

  var body: some View {
    HStack(spacing: 8) {
      if loadState == .refreshing {
        HarnessMonitorSpinner(size: 12)
        Text("Refreshing…").font(captionFont).foregroundStyle(.secondary)
      } else if let statusLabel = countSummary.statusLabel {
        Text(statusLabel)
          .font(captionMonospacedFont)
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

extension DashboardReviewConversationStatusBar: @MainActor Equatable {
  static func == (
    lhs: DashboardReviewConversationStatusBar,
    rhs: DashboardReviewConversationStatusBar
  ) -> Bool {
    // POD comparison: closures don't participate (any onRefresh from
    // the same parent points at the same logic). SwiftUI invalidates
    // when loadState or the rendered event counts actually change.
    lhs.loadState == rhs.loadState && lhs.countSummary == rhs.countSummary
      && lhs.fontScale == rhs.fontScale
  }
}

/// POD position footer — "Showing N (more available)" / "N events" —
/// for the conversation feed's Load Older region. Tracks the rendered
/// row count and the currently visible batch window.
struct DashboardReviewConversationPositionFooter: View {
  let countSummary: DashboardReviewConversationCountSummary
  let fontScale: CGFloat
  let captionMonospacedFont: Font

  init(
    countSummary: DashboardReviewConversationCountSummary,
    fontScale: CGFloat
  ) {
    self.countSummary = countSummary
    self.fontScale = fontScale
    captionMonospacedFont = HarnessMonitorTextSize.scaledFont(
      .caption.monospacedDigit(),
      by: fontScale
    )
  }

  var body: some View {
    Text(countSummary.footerLabel)
      .font(captionMonospacedFont)
      .foregroundStyle(.secondary)
      .accessibilityLabel(Text(countSummary.footerAccessibilityLabel))
  }
}

extension DashboardReviewConversationPositionFooter: @MainActor Equatable {
  static func == (
    lhs: DashboardReviewConversationPositionFooter,
    rhs: DashboardReviewConversationPositionFooter
  ) -> Bool {
    lhs.countSummary == rhs.countSummary && lhs.fontScale == rhs.fontScale
  }
}

struct DashboardReviewConversationCountSummary: Equatable, Sendable {
  let visibleRowsCount: Int
  let totalRowsCount: Int
  let hasOlder: Bool

  var statusLabel: String? {
    guard totalRowsCount > 0 else { return nil }
    return "\(totalRowsCount) events"
  }

  var footerLabel: String {
    if visibleRowsCount < totalRowsCount {
      "Showing \(visibleRowsCount) of \(totalRowsCount) events"
    } else if hasOlder {
      "Showing \(totalRowsCount) (more available)"
    } else {
      "\(totalRowsCount) events"
    }
  }

  var footerAccessibilityLabel: String {
    if visibleRowsCount < totalRowsCount {
      "Showing \(visibleRowsCount) of \(totalRowsCount) events"
    } else if hasOlder {
      "Showing \(totalRowsCount) events, more available"
    } else {
      "Showing all \(totalRowsCount) events"
    }
  }
}
