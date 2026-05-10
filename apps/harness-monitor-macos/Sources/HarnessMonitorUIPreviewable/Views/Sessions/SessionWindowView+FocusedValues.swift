import HarnessMonitorKit
import SwiftUI

extension SessionWindowView {
  func sessionWindowFocusedValues<Content: View>(
    _ content: Content
  ) -> some View {
    content
      .focusedSceneValue(\.sessionNavigation, navigationCommand)
      .focusedSceneValue(\.sessionAttention, attentionFocus)
      .focusedSceneValue(\.sessionInspector, canPresentInspector ? inspectorCommand : nil)
      .focusedSceneValue(\.sessionCreateContext, createContext)
      .focusedSceneValue(\.harnessSessionRouteFocus, sessionRouteFocus)
  }

  var sessionRouteFocus: HarnessSessionRouteFocus? {
    guard let domain = stateCache.selection.routeDomain else { return nil }
    return HarnessSessionRouteFocus(domain: domain, routeID: token.sessionID)
  }
}
