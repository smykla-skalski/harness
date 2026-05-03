import HarnessMonitorKit
import SwiftUI

extension WorkspaceWindowView {
  var currentPrimaryContentFocusTarget: PrimaryContentFocusTarget {
    if case .create = viewModel.selection {
      return .create
    }
    if viewModel.selection.isDecisionRoute {
      return .decisionDetail
    }
    if usesLiveViewportSplitLayout, selectedSessionTui != nil {
      return .liveViewport
    }
    return .genericDetail
  }
}
