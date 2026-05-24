import HarnessMonitorKit
import SwiftUI

/// POD top-of-conversation bar: refresh button + load-state hint.
/// Takes only the values it needs (`loadState`, `entriesCount`,
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
  let entriesCount: Int
  let fontScale: CGFloat
  let onRefresh: () -> Void
  let captionFont: Font
  let captionMonospacedFont: Font

  init(
    loadState: ReviewTimelineViewModel.LoadState,
    entriesCount: Int,
    fontScale: CGFloat,
    onRefresh: @escaping () -> Void
  ) {
    self.loadState = loadState
    self.entriesCount = entriesCount
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
      } else if entriesCount > 0 {
        Text("\(entriesCount) events")
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
    // when loadState or entriesCount actually change.
    lhs.loadState == rhs.loadState && lhs.entriesCount == rhs.entriesCount
      && lhs.fontScale == rhs.fontScale
  }
}

/// POD position footer — "Showing N (more available)" / "N events" —
/// for the conversation feed's Load Older region. Tracks both loaded
/// entry count and the currently rendered row window.
struct DashboardReviewConversationPositionFooter: View {
  let entriesCount: Int
  let visibleRowsCount: Int
  let totalRowsCount: Int
  let hasOlder: Bool
  let fontScale: CGFloat
  let captionMonospacedFont: Font

  init(
    entriesCount: Int,
    visibleRowsCount: Int,
    totalRowsCount: Int,
    hasOlder: Bool,
    fontScale: CGFloat
  ) {
    self.entriesCount = entriesCount
    self.visibleRowsCount = visibleRowsCount
    self.totalRowsCount = totalRowsCount
    self.hasOlder = hasOlder
    self.fontScale = fontScale
    captionMonospacedFont = HarnessMonitorTextSize.scaledFont(
      .caption.monospacedDigit(),
      by: fontScale
    )
  }

  var body: some View {
    Text(label)
      .font(captionMonospacedFont)
      .foregroundStyle(.secondary)
      .accessibilityLabel(Text(accessibilityLabel))
  }

  private var label: String {
    if visibleRowsCount < totalRowsCount {
      "Showing \(visibleRowsCount) of \(totalRowsCount) events"
    } else if hasOlder {
      "Showing \(entriesCount) (more available)"
    } else {
      "\(entriesCount) events"
    }
  }

  private var accessibilityLabel: String {
    if visibleRowsCount < totalRowsCount {
      "Showing \(visibleRowsCount) of \(totalRowsCount) events"
    } else if hasOlder {
      "Showing \(entriesCount) events, more available"
    } else {
      "Showing all \(entriesCount) events"
    }
  }
}

extension DashboardReviewConversationPositionFooter: @MainActor Equatable {
  static func == (
    lhs: DashboardReviewConversationPositionFooter,
    rhs: DashboardReviewConversationPositionFooter
  ) -> Bool {
    lhs.entriesCount == rhs.entriesCount && lhs.visibleRowsCount == rhs.visibleRowsCount
      && lhs.totalRowsCount == rhs.totalRowsCount && lhs.hasOlder == rhs.hasOlder
      && lhs.fontScale == rhs.fontScale
  }
}
