import HarnessMonitorKit
import SwiftUI

@MainActor
struct DecisionRelatedAgentContextSection: View {
  let decision: Decision
  let store: HarnessMonitorStore?

  private var matchingAgent: AgentRegistration? {
    guard
      let store,
      let agentID = nonEmpty(decision.agentID),
      let session = store.selectedSession,
      decision.sessionID == nil || session.session.sessionId == decision.sessionID
    else {
      return nil
    }
    return session.agents.first(where: { $0.agentId == agentID })
  }

  private var matchingTask: WorkItem? {
    guard
      let store,
      let taskID = nonEmpty(decision.taskID),
      let session = store.selectedSession,
      decision.sessionID == nil || session.session.sessionId == decision.sessionID
    else {
      return nil
    }
    return session.tasks.first(where: { $0.taskId == taskID })
  }

  private var workspaceTitle: String? {
    guard let sessionID = nonEmpty(decision.sessionID) else {
      return nil
    }
    if let selectedSession = store?.selectedSession,
      selectedSession.session.sessionId == sessionID
    {
      return selectedSession.session.displayTitle
    }
    return humanizedWorkspaceLabel(sessionID)
  }

  private var facts: [InspectorFact] {
    var values: [InspectorFact] = []
    if let matchingAgent {
      values.append(.init(title: "Agent", value: matchingAgent.name))
      values.append(.init(title: "State", value: matchingAgent.status.title))
      values.append(.init(title: "Role", value: matchingAgent.role.title))
      values.append(.init(title: "Runtime", value: runtimeDisplayLabel(matchingAgent.runtime)))
      if let matchingTask {
        values.append(.init(title: "Task", value: matchingTask.title))
      } else if let taskID = nonEmpty(matchingAgent.currentTaskId ?? decision.taskID) {
        values.append(.init(title: "Task", value: humanizedWorkspaceLabel(taskID)))
      }
    } else {
      if let agentID = nonEmpty(decision.agentID) {
        values.append(.init(title: "Agent", value: humanizedWorkspaceLabel(agentID)))
      }
      if let taskID = nonEmpty(decision.taskID) {
        values.append(.init(title: "Task", value: humanizedWorkspaceLabel(taskID)))
      }
    }
    if let workspaceTitle {
      values.append(.init(title: "Workspace", value: workspaceTitle))
    }
    return values
  }

  private var hasScopeContext: Bool {
    !facts.isEmpty
  }

  var body: some View {
    if hasScopeContext {
      InspectorSection(title: "Related workspace") {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          InspectorFactGrid(facts: facts)
          if let agentID = nonEmpty(decision.agentID), matchingAgent == nil {
            Text("Open the matching workspace to see \(humanizedWorkspaceLabel(agentID)) live.")
            .scaledFont(.footnote)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
          }
          if let agentID = nonEmpty(decision.agentID) {
            Button("Open agent") {
              routeToAgent(agentID)
            }
            .harnessActionButtonStyle(variant: .bordered, tint: nil)
            .accessibilityIdentifier(HarnessMonitorAccessibility.decisionOpenInAgents)
          }
          if let taskID = nonEmpty(decision.taskID) {
            Button("Open task") {
              routeToTask(taskID)
            }
            .harnessActionButtonStyle(variant: .bordered, tint: nil)
          }
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessMonitorAccessibility.decisionRelatedAgentContext)
    }
  }

  private func routeToAgent(_ agentID: String) {
    guard let store else {
      return
    }
    store.requestWorkspaceSelection(.agent(sessionID: decision.sessionID, agentID: agentID))
  }

  private func routeToTask(_ taskID: String) {
    guard let store else {
      return
    }
    store.requestWorkspaceSelection(.task(sessionID: decision.sessionID, taskID: taskID))
  }

  private func nonEmpty(_ value: String?) -> String? {
    guard let value else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
