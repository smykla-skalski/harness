import HarnessMonitorKit
import SwiftUI

struct SessionWindowLifecycleModifier: ViewModifier {
  let store: HarnessMonitorStore
  let sessionID: String
  let tracker: SessionWindowPresenceTracker
  @State private var identity = SessionWindowLifecycleIdentity()

  private var windowID: ObjectIdentifier {
    ObjectIdentifier(identity)
  }

  func body(content: Content) -> some View {
    content
      .task(id: sessionID) { @MainActor in
        activate()
      }
      .onDisappear {
        deactivate()
      }
  }

  private func activate() {
    store.registerOpenSessionWindow(windowID: windowID, sessionID: sessionID)
    tracker.sessionWindowAppeared(windowID: windowID)
    Task { @MainActor [store, sessionID] in
      await store.ensureSessionDetailHydratedForOpenWindow(sessionID: sessionID)
    }
  }

  private func deactivate() {
    store.unregisterOpenSessionWindow(windowID: windowID)
    tracker.sessionWindowDisappeared(windowID: windowID)
  }
}

private final class SessionWindowLifecycleIdentity {}
