import HarnessMonitorKit
import SwiftUI

struct SessionTimelineRowView: View {
  let row: SessionTimelineRow
  let actionHandler: any DecisionActionHandler
  let onSignalTap: ((String) -> Void)?
  let reviewInlineConversationContext: DashboardReviewActivityInlineConversationRendererContext?
  let avatarImageLoader: TimelineAvatarImageLoader?
  let fontScale: CGFloat
  let isFocused: Bool

  init(
    row: SessionTimelineRow,
    actionHandler: any DecisionActionHandler,
    onSignalTap: ((String) -> Void)?,
    reviewInlineConversationContext: DashboardReviewActivityInlineConversationRendererContext? =
      nil,
    avatarImageLoader: TimelineAvatarImageLoader? = nil,
    fontScale: CGFloat,
    isFocused: Bool = false
  ) {
    self.row = row
    self.actionHandler = actionHandler
    self.onSignalTap = onSignalTap
    self.reviewInlineConversationContext = reviewInlineConversationContext
    self.avatarImageLoader = avatarImageLoader
    self.fontScale = fontScale
    self.isFocused = isFocused
  }

  private static let indentStep: CGFloat = 16

  var body: some View {
    SessionTimelineNodeCluster(
      row: row,
      actionHandler: actionHandler,
      onSignalTap: onSignalTap,
      onOpenFullContent: nil,
      fullContentRevision: nil,
      reviewInlineConversationContext: reviewInlineConversationContext,
      avatarImageLoader: avatarImageLoader,
      fontScale: fontScale
    )
    .equatable()
    .padding(
      EdgeInsets(
        top: 0,
        leading: CGFloat(row.node.indentLevel) * Self.indentStep,
        bottom: HarnessMonitorTheme.spacingMD,
        trailing: HarnessMonitorTheme.spacingXS
      )
    )
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .overlay {
      if isFocused {
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM)
          .stroke(HarnessMonitorTheme.accent.opacity(0.85), lineWidth: 2)
      }
    }
  }
}

extension SessionTimelineRowView: @MainActor Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.row == rhs.row
      && lhs.fontScale == rhs.fontScale
      && (lhs.onSignalTap == nil) == (rhs.onSignalTap == nil)
      && (lhs.reviewInlineConversationContext == nil)
        == (rhs.reviewInlineConversationContext == nil)
      && lhs.reviewInlineConversationContext?.viewerLogin
        == rhs.reviewInlineConversationContext?.viewerLogin
      && lhs.reviewInlineConversationContext?.collapseRevision
        == rhs.reviewInlineConversationContext?.collapseRevision
      && (lhs.avatarImageLoader == nil) == (rhs.avatarImageLoader == nil)
      && lhs.isFocused == rhs.isFocused
      && ObjectIdentifier(lhs.actionHandler as AnyObject)
        == ObjectIdentifier(rhs.actionHandler as AnyObject)
  }
}
