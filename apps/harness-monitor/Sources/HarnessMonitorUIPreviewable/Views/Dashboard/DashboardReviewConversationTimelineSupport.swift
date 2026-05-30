import Foundation
import HarnessMonitorKit
import SwiftUI

/// Computes the locally visible rows for the Reviews activity timeline when the
/// middle is collapsed: keep the current leading window visible, preserve a
/// single oldest anchor event at the far edge, and hide only the rows between
/// them.
struct DashboardReviewConversationVisibilityWindow: Equatable {
  let leadingVisibleRowsCount: Int
  let trailingVisibleRowsCount: Int
  let hiddenMiddleRowCount: Int
  let nextExpansionCount: Int

  var visibleRowsCount: Int {
    leadingVisibleRowsCount + trailingVisibleRowsCount
  }

  init(
    totalRowsCount: Int,
    leadingVisibleRowsLimit: Int,
    batchSize: Int,
    trailingAnchorCount: Int
  ) {
    let clampedTotalRowsCount = max(totalRowsCount, 0)
    let clampedLeadingVisibleRowsLimit = min(
      max(leadingVisibleRowsLimit, 0),
      clampedTotalRowsCount
    )
    let clampedTrailingAnchorCount = min(
      max(trailingAnchorCount, 0),
      max(clampedTotalRowsCount - clampedLeadingVisibleRowsLimit, 0)
    )
    let hiddenMiddleRowCount = max(
      clampedTotalRowsCount - clampedLeadingVisibleRowsLimit - clampedTrailingAnchorCount,
      0
    )

    if hiddenMiddleRowCount == 0 {
      leadingVisibleRowsCount = clampedTotalRowsCount
      trailingVisibleRowsCount = 0
    } else {
      leadingVisibleRowsCount = clampedLeadingVisibleRowsLimit
      trailingVisibleRowsCount = clampedTrailingAnchorCount
    }

    self.hiddenMiddleRowCount = hiddenMiddleRowCount
    nextExpansionCount = min(max(batchSize, 0), hiddenMiddleRowCount)
  }
}

enum DashboardReviewConversationCollapsedGapAction: Equatable {
  case show(Int)
  case hide(Int)

  var title: String {
    switch self {
    case .show(let hiddenRowCount):
      "Show \(hiddenRowCount) more events"
    case .hide(let hiddenRowCount):
      "Hide \(hiddenRowCount) events"
    }
  }

  var helpText: String {
    switch self {
    case .show:
      "Render the next batch of hidden review activity"
    case .hide:
      "Hide the events revealed from the collapsed middle"
    }
  }
}

struct DashboardReviewConversationSegmentedTimelineRows<
  HeadRows: RandomAccessCollection,
  TailRows: RandomAccessCollection
>: View where HeadRows.Element == SessionTimelineRow, TailRows.Element == SessionTimelineRow {
  let headRows: HeadRows
  let tailRows: TailRows
  let gapAction: DashboardReviewConversationCollapsedGapAction
  let gapScrollAnchorID: String
  let onGapAnchorMinYChange: (CGFloat) -> Void
  let actionHandler: any DecisionActionHandler
  let onSignalTap: ((String) -> Void)?
  let onOpenFullContent: ((SessionTimelineNode) -> Void)?
  let fullContentRevision: UInt64?
  let reviewInlineConversationContext: ReviewActivityInlineConversationRendererContext?
  let avatarImageLoader: TimelineAvatarImageLoader?
  let fontScale: CGFloat
  let onGapActivate: () -> Void

  var body: some View {
    let firstRowID = headRows.first?.id ?? tailRows.first?.id
    let lastHeadRowID = headRows.last?.id
    let firstTailRowID = tailRows.first?.id
    let lastTailRowID = tailRows.last?.id
    let lastRowID = tailRows.last?.id ?? headRows.last?.id
    LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(headRows) { row in
        SessionTimelineNodeCluster(
          row: row,
          actionHandler: actionHandler,
          onSignalTap: onSignalTap,
          onOpenFullContent: onOpenFullContent,
          fullContentRevision: fullContentRevision,
          reviewInlineConversationContext: reviewInlineConversationContext,
          avatarImageLoader: avatarImageLoader,
          fontScale: fontScale
        )
        .equatable()
        .padding(.bottom, HarnessMonitorTheme.itemSpacing)
      }
      DashboardReviewConversationCollapsedGapDivider(
        action: gapAction,
        anchorID: gapScrollAnchorID,
        onAnchorMinYChange: onGapAnchorMinYChange,
        fontScale: fontScale,
        onExpand: onGapActivate
      )
      .padding(.bottom, HarnessMonitorTheme.itemSpacing)
      ForEach(tailRows) { row in
        SessionTimelineNodeCluster(
          row: row,
          actionHandler: actionHandler,
          onSignalTap: onSignalTap,
          onOpenFullContent: onOpenFullContent,
          fullContentRevision: fullContentRevision,
          reviewInlineConversationContext: reviewInlineConversationContext,
          avatarImageLoader: avatarImageLoader,
          fontScale: fontScale
        )
        .equatable()
        .padding(.bottom, row.id == lastTailRowID ? 0 : HarnessMonitorTheme.itemSpacing)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .coordinateSpace(.named(SessionTimelineRailCoordinateSpace.name))
    .backgroundPreferenceValue(SessionTimelineMarkerBoundsPreferenceKey.self) { anchors in
      if firstRowID != nil, lastRowID != nil {
        ZStack {
          SessionTimelineRailDecoration(
            firstRowID: firstRowID,
            lastRowID: lastRowID,
            markerAnchors: anchors
          )
          DashboardReviewConversationCollapsedGapRailOverlay(
            startRowID: lastHeadRowID,
            endRowID: firstTailRowID,
            markerAnchors: anchors
          )
        }
      }
    }
  }
}
