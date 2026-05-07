import HarnessMonitorKit
import SwiftUI

struct SessionWindowOpenStateModifier: ViewModifier {
  let store: HarnessMonitorStore
  let sessionID: String

  func body(content: Content) -> some View {
    content
      .task {
        store.registerOpenSessionWindow(sessionID: sessionID)
      }
      .onDisappear {
        store.unregisterOpenSessionWindow(sessionID: sessionID)
      }
  }
}
