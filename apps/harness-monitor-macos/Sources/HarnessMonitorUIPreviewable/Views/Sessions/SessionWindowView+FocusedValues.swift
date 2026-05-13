import HarnessMonitorKit
import SwiftUI

extension SessionWindowView {
  func sessionWindowFocusedValues<Content: View>(
    _ content: Content
  ) -> some View {
    let navigation =
      isStartupSearchParticipationEnabled ? navigationCommand : nil

    let attention =
      isStartupSearchParticipationEnabled ? attentionFocus : nil

    let inspector = focusedInspectorCommand

    return
      content
      .harnessFocusedSceneValue(\.sessionNavigation, navigation)
      .harnessFocusedSceneValue(\.sessionAttention, attention)
      .harnessFocusedSceneValue(\.sessionInspector, inspector)
  }

  var focusedInspectorCommand: SessionInspectorCommand? {
    guard isStartupSearchParticipationEnabled else { return nil }
    guard canPresentInspector else { return nil }
    return inspectorCommand
  }
}
