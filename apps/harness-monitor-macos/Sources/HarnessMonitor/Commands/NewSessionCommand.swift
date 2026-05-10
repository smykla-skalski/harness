import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct NewSessionCommand: Commands {
  let store: HarnessMonitorStore
  let sessionCreate: SessionCreateContext?

  var body: some Commands {
    let action = primaryAction
    CommandGroup(after: .newItem) {
      Button(menuTitle) { action?() }
        .keyboardShortcut("n", modifiers: [.command])
        .disabled(action == nil)
    }
  }

  private var menuTitle: String {
    guard let kind = sessionCreate?.primaryKind else { return "New Session" }
    switch kind {
    case .agent: return "New Agent"
    case .task: return "New Task"
    case .decision: return "New Decision"
    }
  }

  private var primaryAction: (() -> Void)? {
    if let sessionCreate {
      switch sessionCreate.primaryKind {
      case .agent:
        return sessionCreate.createAgent
      case .task:
        return sessionCreate.createTask
      case .decision:
        return sessionCreate.createDecision
      }
    }
    guard store.connectionState == .online else {
      return nil
    }
    return { store.presentedSheet = .newSession }
  }
}
