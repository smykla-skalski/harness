import AppKit
import HarnessMonitorKit
import SwiftUI

extension WorkspaceWindowView {
  func restoreSidebarVisibility(
    using binding: Binding<NavigationSplitViewVisibility>
  ) {
    guard binding.wrappedValue == .detailOnly else {
      return
    }
    binding.wrappedValue = .all
    // Capture the workspace contentView synchronously before the async hop so
    // the notification targets this window even if key focus shifts in 50ms.
    // asyncAfter(0.05) gives SwiftUI a full rendering cycle to commit the
    // column-visibility change before VoiceOver re-scans the AX tree.
    let contentView = NSApp.keyWindow?.contentView
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      if let contentView {
        NSAccessibility.post(element: contentView, notification: .layoutChanged)
      }
    }
  }

  func workspaceNavigationTitle(for selection: WorkspaceSelection) -> String {
    switch selection {
    case .create:
      "New"
    case .decisions, .decision:
      "Decisions"
    case .terminal, .codex:
      "Session"
    case .agent(_, let agentID):
      store.selectedSession?.agents.first(where: { $0.agentId == agentID })?.name ?? "Agent"
    case .task(_, let taskID):
      store.selectedSession?.tasks.first(where: { $0.taskId == taskID })?.title ?? "Task"
    }
  }

  func workspaceNavigationSubtitle(for selection: WorkspaceSelection) -> String {
    switch selection {
    case .agent(_, let agentID):
      if let agent = store.selectedSession?.agents.first(where: { $0.agentId == agentID }) {
        return "\(runtimeDisplayLabel(agent.runtime)) · \(agent.role.title)"
      }
      return ""
    default:
      return ""
    }
  }

}
