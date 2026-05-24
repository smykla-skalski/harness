import HarnessMonitorKit
import SwiftUI

extension SessionSidebar {
  func linkTask(_ taskID: String, to decisionID: String) {
    SessionItemContextMenuActionSupport.linkTask(
      state: state,
      taskID: taskID,
      to: decisionID
    )
  }

  func requestRemoveAgents(_ agentIDs: [String]) {
    SessionItemContextMenuActionSupport.requestRemoveAgents(
      store: store,
      sessionID: state.sessionID,
      leaderID: snapshot?.detail?.session.leaderId,
      agents: snapshot?.detail?.agents ?? [],
      agentIDs: agentIDs
    )
  }

  func requestDeleteTasks(_ taskIDs: [String]) {
    SessionItemContextMenuActionSupport.requestDeleteTasks(
      store: store,
      state: state,
      tasks: snapshot?.detail?.tasks ?? [],
      taskIDs: taskIDs
    )
  }

  func sidebarSelection(
    for kind: SessionSidebarSelectionKind,
    id: String
  ) -> SessionSelection {
    switch kind {
    case .agent: .agent(sessionID: state.sessionID, agentID: id)
    case .task: .task(sessionID: state.sessionID, taskID: id)
    case .decision: .decision(sessionID: state.sessionID, decisionID: id)
    }
  }

  func severityShape(for status: AgentStatus) -> SessionSidebarSeverityShape {
    switch status {
    case .active: .dot
    case .awaitingReview: .alert
    case .idle: .none
    case .disconnected, .removed: .ring
    }
  }

  func severityTint(for status: AgentStatus) -> Color {
    switch status {
    case .active, .awaitingReview: .accentColor
    case .idle, .disconnected, .removed: .gray
    }
  }

  func severityShape(for severity: TaskSeverity) -> SessionSidebarSeverityShape {
    switch severity {
    case .low: .none
    case .medium: .dot
    case .high: .ring
    case .critical: .alert
    }
  }

  func severityTint(for severity: TaskSeverity) -> Color {
    switch severity {
    case .low: .gray
    case .medium, .high, .critical: .accentColor
    }
  }

  func severityShape(for severity: DecisionSeverity?) -> SessionSidebarSeverityShape {
    switch severity {
    case .info: .dot
    case .warn: .ring
    case .needsUser, .critical: .alert
    case .none: .none
    }
  }

  func severityTint(for severity: DecisionSeverity?) -> Color {
    switch severity {
    case .info, .none: .gray
    case .warn, .needsUser, .critical: .accentColor
    }
  }
}
