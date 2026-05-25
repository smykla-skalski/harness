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
    guard let sessionID = target.sessionID else {
      throw MobileRelayCommandExecutionError.missingTarget("sessionID")
    }
    return sessionID
  }

  func requiredAgentID() throws -> String {
    guard let agentID = target.agentID else {
      throw MobileRelayCommandExecutionError.missingTarget("agentID")
    }
    return agentID
  }

  func requiredTaskID() throws -> String {
    guard let taskID = target.taskID else {
      throw MobileRelayCommandExecutionError.missingTarget("taskID")
    }
    return taskID
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
      return .approveSome(requestIDs)
    default:
      throw MobileRelayCommandExecutionError.invalidPayload(key: "decision", value: decision)
    }
  }

  func taskBoardDispatchRequest() -> TaskBoardDispatchRequest {
    TaskBoardDispatchRequest(
      status: optionalPayload("status").map(TaskBoardStatus.init(rawValue:)),
      itemId: target.taskID ?? optionalPayload("itemID"),
      dryRun: optionalBoolPayload("dryRun") ?? false,
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
      role: optionalPayload("role").flatMap(SessionRole.init(rawValue:)) ?? .worker,
      fallbackRole: optionalPayload("fallbackRole").flatMap(SessionRole.init(rawValue:)),
      capabilities: csvPayload("capabilities"),
      name: optionalPayload("name"),
      prompt: optionalPayload("prompt"),
      projectDir: optionalPayload("projectDir"),
      persona: optionalPayload("persona"),
      taskID: target.taskID,
      boardItemID: optionalPayload("boardItemID"),
      workflowExecutionID: optionalPayload("workflowExecutionID"),
      model: optionalPayload("model"),
      effort: optionalPayload("effort"),
      allowCustomModel: optionalBoolPayload("allowCustomModel") ?? false,
      recordPermissions: optionalBoolPayload("recordPermissions") ?? true,
      runtime: optionalPayload("runtime"),
      argv: csvPayload("argv"),
      rows: try optionalIntPayload("rows") ?? 32,
      cols: try optionalIntPayload("cols") ?? 120,
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
      target.reviewID ?? optionalPayload("reviewID") ?? optionalPayload("pullRequestID")
    let summary = reviewID.flatMap { id in snapshot.reviews.first { $0.id == id } }
    let repository = optionalPayload("repository") ?? summary?.repository
    let number =
      optionalPayload("number").flatMap(UInt64.init)
      ?? summary.map { UInt64($0.number) }
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
      isDraft: optionalBoolPayload("isDraft") ?? summary?.isDraft ?? false,
      headSha: optionalPayload("headSha") ?? summary?.headSha ?? "",
      mergeable: ReviewMergeableState(
        rawValue: optionalPayload("mergeable") ?? summary?.mergeable ?? "unknown"),
      reviewStatus: ReviewReviewStatus(
        rawValue: optionalPayload("reviewStatus") ?? summary?.reviewStatus ?? "none"),
      checkStatus: ReviewCheckStatus(
        rawValue: optionalPayload("checkStatus") ?? summary?.checkStatus ?? "none"),
      policyBlocked: optionalBoolPayload("policyBlocked") ?? summary?.policyBlocked ?? false,
      requiredFailedCheckNames: csvPayload("requiredFailedCheckNames"),
      viewerCanMergeAsAdmin: optionalBoolPayload("viewerCanMergeAsAdmin") ?? false,
      checkSuiteIDs: csvPayload("checkSuiteIDs"),
      viewerCanUpdate: optionalBoolPayload("viewerCanUpdate") ?? true
    )
  }

  func mergeMethod() -> TaskBoardGitHubMergeMethod {
    TaskBoardGitHubMergeMethod(rawValue: optionalPayload("method") ?? "squash")
  }

  func refreshScope() throws -> MobileRelayRefreshScope {
    let scope = optionalPayload("scope") ?? "health"
    guard let refreshScope = MobileRelayRefreshScope(rawValue: scope) else {
      throw MobileRelayCommandExecutionError.invalidPayload(key: "scope", value: scope)
    }
    return refreshScope
  }

  func optionalBoolPayload(_ key: String) -> Bool? {
    guard let value = optionalPayload(key)?.lowercased() else {
      return nil
    }
    switch value {
    case "1", "true", "yes":
      return true
    case "0", "false", "no":
      return false
    default:
      return nil
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

  func csvPayload(_ key: String) -> [String] {
    optionalPayload(key)?
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      ?? []
  }
}

