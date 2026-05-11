import HarnessMonitorKit
import SwiftUI

struct SessionTimelineRowView: View {
  let row: SessionTimelineRow
  let actionHandler: any DecisionActionHandler
  let onSignalTap: ((String) -> Void)?
  let fontScale: CGFloat

  var body: some View {
    SessionTimelineNodeCluster(
      row: row,
      actionHandler: actionHandler,
      onSignalTap: onSignalTap,
      fontScale: fontScale
    )
    .equatable()
    .padding(
      EdgeInsets(
        top: 0,
        leading: 0,
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
      && ObjectIdentifier(lhs.actionHandler as AnyObject)
        == ObjectIdentifier(rhs.actionHandler as AnyObject)
  }
}
