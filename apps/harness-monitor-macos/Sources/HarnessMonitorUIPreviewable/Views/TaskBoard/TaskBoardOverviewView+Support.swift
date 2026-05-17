import HarnessMonitorKit
import SwiftUI

extension TaskBoardOverviewView {
  private var detailRowHorizontalPadding: CGFloat {
    24
  }

  func taskBoardDetailRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
      .padding(.horizontal, detailRowHorizontalPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  var hasRouteContent: Bool {
    !snapshot.isEmpty || !taskBoardItems.isEmpty || !decisions.isEmpty || orchestratorStatus != nil
      || evaluationSummary != nil
  }

}
