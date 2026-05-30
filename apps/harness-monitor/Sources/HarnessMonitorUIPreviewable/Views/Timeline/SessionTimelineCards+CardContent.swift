import HarnessMonitorKit
import SwiftUI

extension SessionTimelineNodeRow {
  var contentColumn: some View {
    Group {
      if hasCustomInlineConversation {
        renderedCardContent
      } else {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          renderedCardContent
          if !node.actions.isEmpty {
            SessionTimelineActionButtons(actions: node.actions, handler: actionHandler)
              .equatable()
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  var cardContainer: some View {
    Group {
      if hasCustomInlineConversation {
        contentColumn
      } else {
        contentColumn
          .padding(cardInsets)
          .background(SessionTimelineCardBackground(tint: cardTint))
      }
    }
    .alignmentGuide(.sessionTimelineMarkerCenter) { dimensions in
      dimensions[.sessionTimelineFirstLineCenter]
    }
  }

  var renderedCardContent: some View {
    Group {
      if let conversation = node.reviewInlineConversation,
        let reviewInlineConversationContext
      {
        let collapsed = Binding<Bool>(
          get: {
            reviewInlineConversationContext.collapsedThreadIDs[conversation.thread.id]
              ?? conversation.thread.isCollapsed
          },
          set: { collapsed in
            reviewInlineConversationContext.onSetCollapsed(conversation.thread.id, collapsed)
          }
        )
        DashboardReviewInlineThreadCard(
          model: DashboardReviewInlineThreadCardModel(thread: conversation.thread),
          viewerLogin: reviewInlineConversationContext.viewerLogin,
          fontScale: fontScale,
          loadAvatar: avatarImageLoader,
          quotedDiffContext: conversation.quotedDiffContext,
          truncationNotice: conversation.isTruncated
            ? "Some comments are still only available on GitHub."
            : nil,
          collapsed: collapsed,
          onResolveToggle: { desired in
            await reviewInlineConversationContext.onResolveToggle(conversation.thread.id, desired)
          },
          onReply: { body in
            await reviewInlineConversationContext.onReply(conversation.thread.id, body)
          }
        )
      } else if SessionTimelineCardLayout.prefersCompactLayout(for: row) {
        compactContent
      } else {
        wideContent
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
  // ViewThatFits removed: combining `ViewThatFits(in: .horizontal)` with the
  // `.fixedSize` badge strip inside a LazyVStack reproduces an AttributeGraph
  // cycle on macOS 26 SwiftUI. The cycle drives `NSHostingView` async-
  // DisplayLink layout to iterate the ForEach off the MainActor, which trips
  // `_swift_task_checkIsolatedSwift` and crashes the app via libdispatch BUG.
  // `prefersCompactLayout(for:)` already encodes the size decision; a
  // deterministic branch is enough.

  var wideContent: some View {
    HStack(
      alignment: usesSimpleWideLayout ? .center : .top,
      spacing: HarnessMonitorTheme.spacingMD
    ) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
          if node.kind != .event {
            kindBadge
          }
          Text(verbatim: node.title)
            .font(titleFont)
            .foregroundStyle(HarnessMonitorTheme.ink)
            .lineLimit(1)
          Text(verbatim: node.sourceLabel)
            .font(sourceFont)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .lineLimit(1)
        }
        .alignmentGuide(.sessionTimelineFirstLineCenter) { dimensions in
          dimensions[VerticalAlignment.center]
        }
        if let detail = node.detail {
          Text(verbatim: detail)
            .font(detailFont)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      rightBadges
    }
  }

  var compactContent: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
        if node.kind != .event {
          kindBadge
        }
        Text(verbatim: node.sourceLabel)
          .font(compactSourceFont)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(1)
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        rightBadges
      }
      .alignmentGuide(.sessionTimelineFirstLineCenter) { dimensions in
        dimensions[VerticalAlignment.center]
      }

      Text(verbatim: node.title)
        .font(titleFont)
        .foregroundStyle(HarnessMonitorTheme.ink)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)

      if let detail = node.detail {
        Text(verbatim: detail)
          .font(detailFont)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(2)
      }
    }
  }

  var kindBadge: some View {
    SessionTimelineBadge(label: node.kind.label, tint: typeTint, style: .quiet)
      .equatable()
  }

  var rightBadges: some View {
    SessionTimelineBadgeStrip(badges: statusBadges)
  }

  var typeTint: Color {
    switch node.kind {
    case .event:
      cardTint
    case .decision:
      HarnessMonitorTheme.accent
    case .linkedDecision:
      HarnessMonitorTheme.caution
    }
  }

  var cardTint: Color {
    if let eventTone = node.eventTone {
      return eventTone.color
    }
    return node.decision?.severity.color ?? HarnessMonitorTheme.secondaryInk
  }

  static func makeStatusBadges(
    for node: SessionTimelineNode
  ) -> [SessionTimelineStatusBadge] {
    var badges: [SessionTimelineStatusBadge] = []
    if let label = node.statusBadgeLabel {
      let tint = node.eventTone?.color ?? HarnessMonitorTheme.secondaryInk
      badges.append(SessionTimelineStatusBadge(label: label, tint: tint))
    } else if let eventTone = node.eventTone {
      badges.append(SessionTimelineStatusBadge(label: eventTone.badgeLabel, tint: eventTone.color))
    }
    if let decision = node.decision {
      badges.append(
        SessionTimelineStatusBadge(
          label: decision.severity.badgeLabel,
          tint: decision.severity.color
        )
      )
    }
    return badges
  }
}
