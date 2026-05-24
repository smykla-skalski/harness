import Foundation
import HarnessMonitorCore
import HarnessMonitorKit

public enum MobileRelayCommandExecutionError: Error, Equatable, CustomStringConvertible,
  Sendable
{
  case missingTarget(String)
  case missingPayload(String)
  case invalidPayload(key: String, value: String)

  public var description: String {
    switch self {
    case .missingTarget(let field):
      "Mobile command is missing target \(field)."
    case .missingPayload(let key):
      "Mobile command is missing payload \(key)."
    case .invalidPayload(let key, let value):
      "Mobile command payload \(key) has invalid value \(value)."
    }
  }
}

public protocol MobileRelayCommandClient: Sendable {
  func resolveAcpPermission(
    agentID: String,
    batchID: String,
    decision: AcpPermissionDecision
  ) async throws -> String
  func dispatchTaskBoard(_ request: TaskBoardDispatchRequest) async throws -> String
  func approveTaskBoardPlan(id: String, request: TaskBoardPlanApproveRequest) async throws
    -> String
  func startAgent(sessionID: String, request: AcpAgentStartRequest) async throws -> String
  func stopAgent(agentID: String) async throws -> String
  func promptAgent(agentID: String, prompt: String) async throws -> String
  func approvePullRequest(_ target: ReviewTarget) async throws -> String
  func labelPullRequest(_ target: ReviewTarget, label: String) async throws -> String
  func rerunPullRequestChecks(_ target: ReviewTarget) async throws -> String
  func mergePullRequest(_ target: ReviewTarget, method: TaskBoardGitHubMergeMethod) async throws
    -> String
  func refresh(scope: MobileRelayRefreshScope, target: ReviewTarget?) async throws -> String
}

public enum MobileRelayRefreshScope: String, Equatable, Sendable {
  case health
  case reviews
  case taskBoard
}

public struct HarnessMonitorClientMobileRelayCommandClient: MobileRelayCommandClient {
  private let client: any HarnessMonitorClientProtocol

  public init(client: any HarnessMonitorClientProtocol) {
    self.client = client
  }

  public func resolveAcpPermission(
    agentID: String,
    batchID: String,
    decision: AcpPermissionDecision
  ) async throws -> String {
    let snapshot = try await client.resolveManagedAcpPermission(
      agentID: agentID,
      batchID: batchID,
      decision: decision
    )
    return "Resolved ACP permission for \(snapshot.managedAgentID)."
  }

  public func dispatchTaskBoard(_ request: TaskBoardDispatchRequest) async throws -> String {
    let summary = try await client.dispatchTaskBoard(request: request)
    return "Dispatched \(summary.applied.count) task board item(s)."
  }

  public func approveTaskBoardPlan(
    id: String,
    request: TaskBoardPlanApproveRequest
  ) async throws -> String {
    let response = try await client.approveTaskBoardPlan(id: id, request: request)
    return "Approved task board plan for \(response.item.title)."
  }

  public func startAgent(sessionID: String, request: AcpAgentStartRequest) async throws -> String {
    let snapshot = try await client.startManagedAcpAgent(sessionID: sessionID, request: request)
    return "Started \(snapshot.managedAgentID)."
  }

  public func stopAgent(agentID: String) async throws -> String {
    let snapshot = try await client.stopManagedAcpAgent(agentID: agentID)
    return "Stopped \(snapshot.managedAgentID)."
  }

  public func promptAgent(agentID: String, prompt: String) async throws -> String {
    let snapshot = try await client.promptManagedAcpAgent(agentID: agentID, prompt: prompt)
    return "Prompted \(snapshot.managedAgentID)."
  }

  public func approvePullRequest(_ target: ReviewTarget) async throws -> String {
    let response = try await client.approveReviews(
      request: ReviewsApproveRequest(targets: [target]))
    return response.summary
  }

  public func labelPullRequest(_ target: ReviewTarget, label: String) async throws -> String {
    let response = try await client.addReviewLabel(
      request: ReviewsLabelRequest(targets: [target], label: label)
    )
    return response.summary
  }

  public func rerunPullRequestChecks(_ target: ReviewTarget) async throws -> String {
    let response = try await client.rerunReviewChecks(
      request: ReviewsRerunChecksRequest(targets: [target])
    )
    return response.summary
  }

  public func mergePullRequest(
    _ target: ReviewTarget,
    method: TaskBoardGitHubMergeMethod
  ) async throws -> String {
    let response = try await client.mergeReviews(
      request: ReviewsMergeRequest(targets: [target], method: method)
    )
    return response.summary
  }

  public func refresh(scope: MobileRelayRefreshScope, target: ReviewTarget?) async throws -> String
  {
    switch scope {
    case .health:
      let health = try await client.health()
      return "Refreshed daemon health: \(health.status)."
    case .reviews:
      guard let target else {
        let health = try await client.health()
        return "Refreshed daemon health: \(health.status)."
      }
      let response = try await client.refreshReviews(
        request: ReviewsRefreshRequest(targets: [target]))
      return "Refreshed \(response.items.count) review(s)."
    case .taskBoard:
      _ = try await client.syncTaskBoard(request: TaskBoardSyncRequest())
      return "Synced task board."
    }
  }
}

public struct HarnessMonitorClientMobileRelayCommandExecutor: MobileRelayCommandExecutor {
  private let client: any MobileRelayCommandClient
  private let now: @Sendable () -> Date

  public init(
    client: any MobileRelayCommandClient,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.client = client
    self.now = now
  }

  public func execute(
    _ command: MobileCommandRecord,
    snapshot: MobileMirrorSnapshot
  ) async throws -> MobileCommandReceipt {
    let message = try await executeCommand(command, snapshot: snapshot)
    let completedAt = now()
    return MobileCommandReceipt(
      commandID: command.id,
      stationID: command.stationID,
      status: .succeeded,
      message: message,
      receivedAt: completedAt,
      completedAt: completedAt,
      executionRevision: snapshot.revision
    )
  }

  private func executeCommand(
    _ command: MobileCommandRecord,
    snapshot: MobileMirrorSnapshot
  ) async throws -> String {
    switch command.kind {
    case .acpPermissionDecision:
      return try await client.resolveAcpPermission(
        agentID: try command.requiredAgentID(),
        batchID: try command.requiredPayload("batchID"),
        decision: try command.acpPermissionDecision()
      )
    case .taskBoardDispatch:
      return try await client.dispatchTaskBoard(command.taskBoardDispatchRequest())
    case .taskBoardPlanApproval:
      return try await client.approveTaskBoardPlan(
        id: try command.requiredTaskID(),
        request: command.taskBoardPlanApproveRequest()
      )
    case .agentStart:
      return try await client.startAgent(
        sessionID: try command.requiredSessionID(),
        request: try command.acpAgentStartRequest()
      )
    case .agentStop:
      return try await client.stopAgent(agentID: try command.requiredAgentID())
    case .agentPrompt:
      return try await client.promptAgent(
        agentID: try command.requiredAgentID(),
        prompt: try command.requiredPayload("prompt")
      )
    case .pullRequestApprove:
      return try await client.approvePullRequest(command.reviewTarget(snapshot: snapshot))
    case .pullRequestLabel:
      return try await client.labelPullRequest(
        command.reviewTarget(snapshot: snapshot),
        label: try command.requiredPayload("label")
      )
    case .pullRequestRerunChecks:
      return try await client.rerunPullRequestChecks(command.reviewTarget(snapshot: snapshot))
    case .pullRequestMerge:
      return try await client.mergePullRequest(
        command.reviewTarget(snapshot: snapshot),
        method: command.mergeMethod()
      )
    case .refresh:
      return try await client.refresh(
        scope: command.refreshScope(),
        target: try command.optionalReviewTarget(snapshot: snapshot)
      )
    }
  }
}

extension MobileCommandRecord {
  fileprivate func requiredPayload(_ key: String) throws -> String {
    guard let value = payload[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else {
      throw MobileRelayCommandExecutionError.missingPayload(key)
    }
    return value
  }

  fileprivate func optionalPayload(_ key: String) -> String? {
    guard let value = payload[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else {
      return nil
    }
    return value
  }

  fileprivate func requiredSessionID() throws -> String {
    guard let sessionID = target.sessionID else {
      throw MobileRelayCommandExecutionError.missingTarget("sessionID")
    }
    return sessionID
  }

  fileprivate func requiredAgentID() throws -> String {
    guard let agentID = target.agentID else {
      throw MobileRelayCommandExecutionError.missingTarget("agentID")
    }
    return agentID
  }

  fileprivate func requiredTaskID() throws -> String {
    guard let taskID = target.taskID else {
      throw MobileRelayCommandExecutionError.missingTarget("taskID")
    }
    return taskID
  }

  fileprivate func acpPermissionDecision() throws -> AcpPermissionDecision {
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

  fileprivate func taskBoardDispatchRequest() -> TaskBoardDispatchRequest {
    TaskBoardDispatchRequest(
      status: optionalPayload("status").map(TaskBoardStatus.init(rawValue:)),
      itemId: target.taskID ?? optionalPayload("itemID"),
      dryRun: optionalBoolPayload("dryRun") ?? false,
      projectDir: optionalPayload("projectDir"),
      actor: actorDeviceID
    )
  }

  fileprivate func taskBoardPlanApproveRequest() -> TaskBoardPlanApproveRequest {
    TaskBoardPlanApproveRequest(
      approvedBy: optionalPayload("approvedBy") ?? actorDeviceID,
      approvedAt: optionalPayload("approvedAt")
    )
  }

  fileprivate func acpAgentStartRequest() throws -> AcpAgentStartRequest {
    AcpAgentStartRequest(
      agent: try requiredPayload("agent"),
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
      recordPermissions: optionalBoolPayload("recordPermissions") ?? true
    )
  }

  fileprivate func reviewTarget(snapshot: MobileMirrorSnapshot) throws -> ReviewTarget {
    guard let target = try optionalReviewTarget(snapshot: snapshot) else {
      throw MobileRelayCommandExecutionError.missingTarget("reviewID")
    }
    return target
  }

  fileprivate func optionalReviewTarget(snapshot: MobileMirrorSnapshot) throws -> ReviewTarget? {
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

  fileprivate func mergeMethod() -> TaskBoardGitHubMergeMethod {
    TaskBoardGitHubMergeMethod(rawValue: optionalPayload("method") ?? "squash")
  }

  fileprivate func refreshScope() -> MobileRelayRefreshScope {
    MobileRelayRefreshScope(rawValue: optionalPayload("scope") ?? "health") ?? .health
  }

  private func optionalBoolPayload(_ key: String) -> Bool? {
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

  private func csvPayload(_ key: String) -> [String] {
    optionalPayload(key)?
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      ?? []
  }
}
