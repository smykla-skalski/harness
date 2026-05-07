import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct NewSessionCommand: Commands {
  let store: HarnessMonitorStore
  @FocusedValue(\.sessionCreateContext)
  private var sessionCreate

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button(menuTitle) { handle() }
        .keyboardShortcut("n", modifiers: [.command])
        .disabled(isDisabled)
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

  private func handle() {
    if let sessionCreate {
      switch sessionCreate.primaryKind {
      case .agent: sessionCreate.createAgent()
      case .task: sessionCreate.createTask()
      case .decision: sessionCreate.createDecision()
      }
    } else {
      store.presentedSheet = .newSession
    }
  }

  private var isDisabled: Bool {
    sessionCreate == nil && store.connectionState != .online
  }
}
