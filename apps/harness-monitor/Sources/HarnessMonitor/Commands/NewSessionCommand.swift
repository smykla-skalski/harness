import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct NewSessionCommand: Commands {
  let store: HarnessMonitorStore
  let keyWindowObserver: KeyWindowObserver
  let windowCommandRouting: WindowCommandRoutingState

  var body: some Commands {
    let action = primaryAction
    CommandGroup(replacing: .newItem) {
      Button("New Session") { action?() }
        .keyboardShortcut("n", modifiers: [.command])
        .disabled(action == nil)
    }
  }

  private var trackedKeyWindowIdentifier: String? {
    let keyWindowIdentifier = keyWindowObserver.snapshot.keyWindowIdentifier
    guard
      keyWindowIdentifier == HarnessMonitorWindowID.dashboard
        || keyWindowIdentifier?.hasPrefix("session-") == true
    else {
      return nil
    }
    return keyWindowIdentifier
  }

  private var presentsOnTrackedWindow: Bool {
    trackedKeyWindowIdentifier != nil
      || windowCommandRouting.activeScope == .main
      || windowCommandRouting.activeScope == .session
  }

  private var primaryAction: (() -> Void)? {
    guard presentsOnTrackedWindow else {
      return nil
    }
    return { store.presentedSheet = .newSession }
  }
}
