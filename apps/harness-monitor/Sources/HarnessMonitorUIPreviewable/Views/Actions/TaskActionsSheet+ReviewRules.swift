import HarnessMonitorKit

extension TaskActionsSheet {
  nonisolated static func eligibleAssignmentAgents(
    _ agents: [AgentRegistration]
  ) -> [AgentRegistration] {
    agents.filter { agent in
      agent.role == .worker
        && matchesAssignmentStatus(agent.status)
        && agent.currentTaskId == nil
    }
  }

  nonisolated static func eligibleReviewClaimAgents(
    task: WorkItem,
    agents: [AgentRegistration]
  ) -> [AgentRegistration] {
    guard task.status == .awaitingReview || task.status == .inReview else { return [] }
    let claimedRuntimes = Set(task.reviewClaim?.reviewers.map(\.reviewerRuntime) ?? [])
    return agents.filter { agent in
      (agent.role == .reviewer || agent.role == .leader)
        && matchesAliveStatus(agent.status)
        && !claimedRuntimes.contains(agent.runtime)
    }
  }

  nonisolated static func eligibleReviewSubmitAgents(
    task: WorkItem,
    agents: [AgentRegistration]
  ) -> [AgentRegistration] {
    guard task.status == .inReview else { return [] }
    let claimedAgentIDs = Set(task.reviewClaim?.reviewers.map(\.reviewerAgentId) ?? [])
    return agents.filter { agent in
      claimedAgentIDs.contains(agent.agentId) && matchesAliveStatus(agent.status)
    }
  }

  nonisolated static func submitForReviewActorID(
    for task: WorkItem,
    agents: [AgentRegistration]
  ) -> String? {
    guard task.status == .inProgress,
      let assignedTo = task.assignedTo,
      let agent = agents.first(where: { $0.agentId == assignedTo }),
      agent.role == .worker,
      matchesAliveStatus(agent.status)
    else {
      return nil
    }
    return assignedTo
  }

  nonisolated static func respondReviewActorID(
    for task: WorkItem,
    agents: [AgentRegistration]
  ) -> String? {
    guard task.status == .inReview,
      task.consensus != nil,
      let submitterID = task.awaitingReview?.submitterAgentId,
      let agent = agents.first(where: { $0.agentId == submitterID }),
      matchesAliveStatus(agent.status)
    else {
      return nil
    }
    return submitterID
  }

  nonisolated static func shouldShowReviewResponse(for task: WorkItem) -> Bool {
    task.status == .inReview && task.consensus != nil
  }

  nonisolated static func arbitrationActorID(
    for task: WorkItem,
    leaderID: String?,
    agents: [AgentRegistration]
  ) -> String? {
    guard isArbitrationBlocked(task),
      let leaderID,
      let leader = agents.first(where: { $0.agentId == leaderID }),
      matchesAliveStatus(leader.status)
    else {
      return nil
    }
    return leaderID
  }

  nonisolated static func isArbitrationBlocked(_ task: WorkItem) -> Bool {
    task.status == .blocked
      && task.blockedReason == "awaiting_arbitration"
      && task.reviewRound >= 3
  }

  nonisolated static func normalizedAgentID(
    draftID: String,
    availableAgentIDs: [String]
  ) -> String {
    if availableAgentIDs.contains(draftID) {
      return draftID
    }
    return availableAgentIDs.first ?? ""
  }

  nonisolated static func normalizedTaskID(
    draftID: String,
    currentTaskID: String?,
    availableTaskIDs: [String]
  ) -> String {
    if let currentTaskID, availableTaskIDs.contains(currentTaskID) {
      return currentTaskID
    }
    if availableTaskIDs.contains(draftID) {
      return draftID
    }
    return availableTaskIDs.first ?? ""
  }

  nonisolated static func normalizedAssigneeID(
    draftID: String,
    assignedAgentID: String?,
    availableAgentIDs: [String]
  ) -> String {
    if availableAgentIDs.contains(draftID) {
      return draftID
    }
    if let assignedAgentID, availableAgentIDs.contains(assignedAgentID) {
      return assignedAgentID
    }
    return availableAgentIDs.first ?? ""
  }

  nonisolated static func matchesReviewQueueStatus(_ task: WorkItem) -> Bool {
    task.status == .awaitingReview || task.status == .inReview
  }

  nonisolated private static func matchesAliveStatus(_ status: AgentStatus) -> Bool {
    switch status {
    case .active, .idle, .awaitingReview:
      true
    case .disconnected, .removed:
      false
    }
  }

  nonisolated private static func matchesAssignmentStatus(_ status: AgentStatus) -> Bool {
    switch status {
    case .active, .idle:
      true
    case .awaitingReview, .disconnected, .removed:
      false
    }
  }
}
