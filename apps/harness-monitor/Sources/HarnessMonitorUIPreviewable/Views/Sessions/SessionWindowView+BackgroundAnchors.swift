import HarnessMonitorKit
import SwiftUI

extension SessionWindowView {
  func sessionWindowBackgroundAnchors(
    currentModifiers: Binding<EventModifiers>
  ) -> some View {
    ZStack {
      SessionWindowSearchMirror(stateCache: stateCache, renderedRoute: renderedRoute)
      appSearchIndexUpdaterAnchor
      SessionWindowModifierKeysMonitor(currentModifiers: currentModifiers)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
  }
}
