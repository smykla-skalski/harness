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
  }
}
