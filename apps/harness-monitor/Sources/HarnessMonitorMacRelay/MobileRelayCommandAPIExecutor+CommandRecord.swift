import Foundation
import HarnessMonitorCore
import HarnessMonitorKit

extension MobileCommandRecord {
  func requiredPayload(_ key: String) throws -> String {
    guard let value = payload[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else {
      throw MobileRelayCommandExecutionError.missingPayload(key)
    }
    return value
  }

  func optionalPayload(_ key: String) -> String? {
    guard let value = payload[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else {
      return nil
    }
    return value
  }

  func requiredSessionID() throws -> String {
    guard let sessionID = optionalTargetValue(target.sessionID) else {
      throw MobileRelayCommandExecutionError.missingTarget("sessionID")
    }
    return sessionID
  }

  func requiredAgentID() throws -> String {
    guard let agentID = optionalTargetValue(target.agentID) else {
      throw MobileRelayCommandExecutionError.missingTarget("agentID")
    }
    return agentID
  }

  func requiredTaskID() throws -> String {
    guard let taskID = optionalTargetValue(target.taskID) else {
      throw MobileRelayCommandExecutionError.missingTarget("taskID")
    }
    return taskID
  }

  func optionalTaskID() -> String? {
    optionalTargetValue(target.taskID)
  }

  func acpPermissionDecision() throws -> AcpPermissionDecision {
    let decision = try requiredPayload("decision")
    switch decision {
    case "approve_all", "approveAll", "approve":
      return .approveAll
    case "deny_all", "denyAll", "deny":
      return .denyAll
    case "approve_some", "approveSome":
      let requestIDs =
        optionalPayload("requestIDs")?
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        ?? []
      guard !requestIDs.isEmpty else {
        throw MobileRelayCommandExecutionError.missingPayload("requestIDs")
      }
      return .approveSome(requestIDs)
    default:
      throw MobileRelayCommandExecutionError.invalidPayload(key: "decision", value: decision)
    }
  }

  func taskBoardDispatchRequest() throws -> TaskBoardDispatchRequest {
    let itemID = optionalTaskID() ?? optionalPayload("itemID")
    guard let itemID else {
      throw MobileRelayCommandExecutionError.missingTarget("taskID")
    }
    return TaskBoardDispatchRequest(
      status: try optionalTaskBoardStatusPayload("status"),
      itemId: itemID,
      dryRun: try optionalBoolPayload("dryRun") ?? false,
      projectDir: optionalPayload("projectDir"),
      actor: actorDeviceID
    )
  }

  func taskBoardPlanApproveRequest() -> TaskBoardPlanApproveRequest {
    TaskBoardPlanApproveRequest(
      approvedBy: optionalPayload("approvedBy") ?? actorDeviceID,
      approvedAt: optionalPayload("approvedAt")
    )
  }

  func agentStartRequest() throws -> MobileRelayAgentStartRequest {
    let agent = try requiredPayload("agent")
    return MobileRelayAgentStartRequest(
      family: try agentStartFamily(agent: agent),
      agent: agent,
      actor: actorDeviceID,
      role: try optionalSessionRolePayload("role") ?? .worker,
      fallbackRole: try optionalSessionRolePayload("fallbackRole"),
      capabilities: csvPayload("capabilities"),
      name: optionalPayload("name"),
      prompt: optionalPayload("prompt"),
      projectDir: optionalPayload("projectDir"),
      persona: optionalPayload("persona"),
      taskID: optionalTaskID(),
      boardItemID: optionalPayload("boardItemID"),
      workflowExecutionID: optionalPayload("workflowExecutionID"),
      model: optionalPayload("model"),
      effort: optionalPayload("effort"),
      allowCustomModel: try optionalBoolPayload("allowCustomModel") ?? false,
      recordPermissions: try optionalBoolPayload("recordPermissions") ?? true,
      runtime: optionalPayload("runtime"),
      argv: csvPayload("argv"),
      rows: try optionalPositiveIntPayload("rows") ?? 32,
      cols: try optionalPositiveIntPayload("cols") ?? 120,
      mode: try codexRunMode()
    )
  }

  func agentStartFamily(agent: String) throws -> MobileRelayAgentStartFamily {
    if let explicitFamily = optionalPayload("family") {
      guard let family = MobileRelayAgentStartFamily(rawValue: explicitFamily.lowercased()) else {
        throw MobileRelayCommandExecutionError.invalidPayload(
          key: "family",
          value: explicitFamily
        )
      }
      return family
    }
    let normalizedAgent = agent.lowercased()
    if normalizedAgent.hasPrefix("terminal:") || normalizedAgent.hasPrefix("tui:") {
      return .terminal
    }
    if normalizedAgent.hasPrefix("acp:") {
      return .acp
    }
    if normalizedAgent == "codex" || normalizedAgent == "codex-native"
      || normalizedAgent == "codex-run"
    {
      return .codex
    }
    if AgentTuiRuntime(rawValue: normalizedAgent) != nil {
      return .terminal
    }
    return .acp
  }

  func codexRunMode() throws -> CodexRunMode {
    guard let rawMode = optionalPayload("mode") else {
      return .workspaceWrite
    }
    guard let mode = CodexRunMode(rawValue: rawMode) else {
      throw MobileRelayCommandExecutionError.invalidPayload(key: "mode", value: rawMode)
    }
    return mode
  }

  func reviewTarget(snapshot: MobileMirrorSnapshot) throws -> ReviewTarget {
    guard let target = try optionalReviewTarget(snapshot: snapshot) else {
      throw MobileRelayCommandExecutionError.missingTarget("reviewID")
    }
    return target
  }

  func optionalReviewTarget(snapshot: MobileMirrorSnapshot) throws -> ReviewTarget? {
    let reviewID =
      optionalTargetValue(target.reviewID) ?? optionalPayload("reviewID") ?? optionalPayload(
        "pullRequestID")
    let summary = reviewID.flatMap { id in snapshot.reviews.first { $0.id == id } }
    let repository = optionalPayload("repository") ?? summary?.repository
    let number = try optionalPositiveUInt64Payload("number") ?? summary.map { UInt64($0.number) }
    guard let repository, let number else {
      if reviewID == nil {
        return nil
      }
      throw MobileRelayCommandExecutionError.missingPayload("repository/number")
    }
    let pullRequestID = optionalPayload("pullRequestID") ?? reviewID ?? "\(repository)#\(number)"
    let repositoryID = optionalPayload("repositoryID") ?? summary?.repositoryID ?? repository
    let url =
      optionalPayload("url") ?? summary?.url ?? "https://github.com/\(repository)/pull/\(number)"
    return ReviewTarget(
      pullRequestID: pullRequestID,
      repositoryID: repositoryID,
      repository: repository,
      number: number,
      url: url,
      state: ReviewPullRequestState(rawValue: optionalPayload("state") ?? summary?.state ?? "open"),
      isDraft: try optionalBoolPayload("isDraft") ?? summary?.isDraft ?? false,
      headSha: optionalPayload("headSha") ?? summary?.headSha ?? "",
      mergeable: ReviewMergeableState(
        rawValue: optionalPayload("mergeable") ?? summary?.mergeable ?? "unknown"),
      reviewStatus: ReviewReviewStatus(
        rawValue: optionalPayload("reviewStatus") ?? summary?.reviewStatus ?? "none"),
      checkStatus: ReviewCheckStatus(
        rawValue: optionalPayload("checkStatus") ?? summary?.checkStatus ?? "none"),
      policyBlocked: try optionalBoolPayload("policyBlocked") ?? summary?.policyBlocked ?? false,
      requiredFailedCheckNames: csvPayload("requiredFailedCheckNames"),
      viewerCanMergeAsAdmin: try optionalBoolPayload("viewerCanMergeAsAdmin") ?? false,
      checkSuiteIDs: csvPayload("checkSuiteIDs"),
      viewerCanUpdate: try optionalBoolPayload("viewerCanUpdate") ?? true
    )
  }

  func mergeMethod() throws -> TaskBoardGitHubMergeMethod {
    let rawMethod = optionalPayload("method") ?? "squash"
    let method = TaskBoardGitHubMergeMethod(rawValue: rawMethod)
    guard case .unknown = method else {
      return method
    }
    throw MobileRelayCommandExecutionError.invalidPayload(key: "method", value: rawMethod)
  }

  func optionalTaskBoardStatusPayload(_ key: String) throws -> TaskBoardStatus? {
    guard let value = optionalPayload(key) else {
      return nil
    }
    let status = TaskBoardStatus(rawValue: value)
    guard case .unknown = status else {
      return status
    }
    throw MobileRelayCommandExecutionError.invalidPayload(key: key, value: value)
  }

  func refreshScope() throws -> MobileRelayRefreshScope {
    let scope = optionalPayload("scope") ?? "health"
    guard let refreshScope = MobileRelayRefreshScope(rawValue: scope) else {
      throw MobileRelayCommandExecutionError.invalidPayload(key: "scope", value: scope)
    }
    return refreshScope
  }

  func optionalBoolPayload(_ key: String) throws -> Bool? {
    guard let value = optionalPayload(key)?.lowercased() else {
      return nil
    }
    switch value {
    case "1", "true", "yes":
      return true
    case "0", "false", "no":
      return false
    default:
      throw MobileRelayCommandExecutionError.invalidPayload(key: key, value: value)
    }
  }

  func optionalIntPayload(_ key: String) throws -> Int? {
    guard let value = optionalPayload(key) else {
      return nil
    }
    guard let intValue = Int(value) else {
      throw MobileRelayCommandExecutionError.invalidPayload(key: key, value: value)
    }
    return intValue
  }

  func optionalPositiveIntPayload(_ key: String) throws -> Int? {
    guard let intValue = try optionalIntPayload(key) else {
      return nil
    }
    guard intValue > 0 else {
      throw MobileRelayCommandExecutionError.invalidPayload(key: key, value: String(intValue))
    }
    return intValue
  }

  func optionalPositiveUInt64Payload(_ key: String) throws -> UInt64? {
    guard let value = optionalPayload(key) else {
      return nil
    }
    guard let uintValue = UInt64(value), uintValue > 0 else {
      throw MobileRelayCommandExecutionError.invalidPayload(key: key, value: value)
    }
    return uintValue
  }

  func optionalSessionRolePayload(_ key: String) throws -> SessionRole? {
    guard let value = optionalPayload(key) else {
      return nil
    }
    guard let role = SessionRole(rawValue: value) else {
      throw MobileRelayCommandExecutionError.invalidPayload(key: key, value: value)
    }
    return role
  }

  func csvPayload(_ key: String) -> [String] {
    optionalPayload(key)?
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      ?? []
  }

  private func optionalTargetValue(_ value: String?) -> String? {
    guard let value else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
