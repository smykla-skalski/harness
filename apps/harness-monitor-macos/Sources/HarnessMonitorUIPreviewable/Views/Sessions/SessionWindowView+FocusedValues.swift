import HarnessMonitorKit
import SwiftUI

extension SessionWindowView {
  func sessionWindowFocusedValues<Content: View>(
    _ content: Content
  ) -> some View {
    content
      .harnessFocusedSceneValue(\.sessionNavigation, navigationCommand)
      .harnessFocusedSceneValue(\.sessionAttention, attentionFocus)
      .harnessFocusedSceneValue(\.sessionInspector, canPresentInspector ? inspectorCommand : nil)
      .harnessFocusedSceneValue(\.harnessSessionRouteFocus, sessionRouteFocus)
  }

  var sessionRouteFocus: HarnessSessionRouteFocus? {
    guard let domain = stateCache.selection.routeDomain else { return nil }
    return HarnessSessionRouteFocus(domain: domain, routeID: token.sessionID)
  }
}
