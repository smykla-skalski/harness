import SwiftUI

struct SupervisorBindingsModifier: ViewModifier {
  let tracker: SessionWindowPresenceTracker

  func body(content: Content) -> some View {
    content
      .task {
        tracker.sessionWindowAppeared()
      }
      .onDisappear {
        tracker.sessionWindowDisappeared()
      }
  }
}
