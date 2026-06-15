import Foundation
import HarnessMonitorKit
import SwiftUI

extension DashboardReviewConversationFeed {
  // Inputs for the timeline rows region, precomputed inside `content`. Bundling
  // them keeps the rendering helper within the parameter-count budget while the
  // row slices and gap actions stay computed alongside the windows that derive
  // them.
  struct TimelineRowsRegion {
    let window: DashboardReviewConversationVisibilityWindow
    let collapsedWindow: DashboardReviewConversationVisibilityWindow
    let canHideRevealedRows: Bool
    let visibleHeadRows: ArraySlice<SessionTimelineRow>
    let visibleTailRows: ArraySlice<SessionTimelineRow>
    let expandedHeadRows: ArraySlice<SessionTimelineRow>
    let expandedTailRows: ArraySlice<SessionTimelineRow>
    let revision: UInt64
    let hasOlder: Bool
    let isLoadingOlder: Bool
    let avatarImageLoader: TimelineAvatarImageLoader
    let openFullContent: (SessionTimelineNode) -> Void
    let inlineConversationContext: ReviewActivityInlineConversationRendererContext
  }

  @ViewBuilder
  func composer(_ viewModel: ReviewTimelineViewModel) -> some View {
    DashboardReviewCommentComposer(
      pullRequestID: item.pullRequestID,
      initialDraft: store.reviewCommentDraft(for: item.pullRequestID),
      viewerCanComment: viewModel.viewerCanComment,
      fontScale: fontScale,
      onDraftChange: { draft in
        store.scheduleReviewDraftWrite(item.pullRequestID, draft: draft)
      },
      onSend: { body in
        await store.postReviewComment(for: item, body: body)
      }
    )
  }

  func rebuildKey(
    _ viewModel: ReviewTimelineViewModel,
    preferences: DashboardReviewsPreferences
  ) -> String {
    let zone = dateTimeConfiguration.customTimeZoneIdentifier
    let cursor = viewModel.startCursor ?? ""
    let showsActivity = preferences.showActivityTimeline.description
    let showsInlineComments = preferences.showActivityInlineComments.description
    let collapsesHeavyThreads = preferences.timelineAutoCollapseHeavyReviewThreads.description
    return "\(viewModel.revision):\(cursor):\(zone):\(preferences.timelineHiddenKindsRaw):"
      + "\(showsActivity):\(showsInlineComments):\(collapsesHeavyThreads)"
  }

  func loadKey(_ preferences: DashboardReviewsPreferences) -> ReviewTimelineTaskKey {
    ReviewTimelineTaskKey(
      item: item,
      isDaemonOnline: store.connectionState == .online,
      pageSize: preferences.normalizedTimelineInitialPageSize,
      isActive: preferences.showActivityTimeline
    )
  }

  var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  var subheadlineFont: Font {
    HarnessMonitorTextSize.scaledFont(.subheadline, by: fontScale)
  }

  var gapScrollAnchorID: String {
    "dashboard.review.timeline.gap-anchor.\(item.pullRequestID)"
  }
}
