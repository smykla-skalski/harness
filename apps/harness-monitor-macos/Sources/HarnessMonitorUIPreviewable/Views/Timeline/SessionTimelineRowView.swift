import HarnessMonitorKit
import SwiftUI

struct SessionTimelineRowView: View {
  let row: SessionTimelineRow
  let actionHandler: any DecisionActionHandler
  let onSignalTap: ((String) -> Void)?
  let avatarImageLoader: TimelineAvatarImageLoader?
  let fontScale: CGFloat

  init(
    row: SessionTimelineRow,
    actionHandler: any DecisionActionHandler,
    onSignalTap: ((String) -> Void)?,
    avatarImageLoader: TimelineAvatarImageLoader? = nil,
    fontScale: CGFloat
  ) {
    self.row = row
    self.actionHandler = actionHandler
    self.onSignalTap = onSignalTap
    self.avatarImageLoader = avatarImageLoader
    self.fontScale = fontScale
  }

  private static let indentStep: CGFloat = 16

  var body: some View {
    SessionTimelineNodeCluster(
      row: row,
      actionHandler: actionHandler,
      onSignalTap: onSignalTap,
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
  }
}

extension SessionTimelineRowView: @MainActor Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.row == rhs.row
      && lhs.fontScale == rhs.fontScale
      && (lhs.onSignalTap == nil) == (rhs.onSignalTap == nil)
      && (lhs.avatarImageLoader == nil) == (rhs.avatarImageLoader == nil)
      && ObjectIdentifier(lhs.actionHandler as AnyObject)
        == ObjectIdentifier(rhs.actionHandler as AnyObject)
  }
}
