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

public enum MobileRelayAgentStartFamily: String, Equatable, Sendable {
  case terminal
  case codex
  case acp
}

public struct MobileRelayAgentStartRequest: Equatable, Sendable {
  public let family: MobileRelayAgentStartFamily
  public let agent: String
  public let actor: String
  public let role: SessionRole
  public let fallbackRole: SessionRole?
  public let capabilities: [String]
  public let name: String?
  public let prompt: String?
  public let projectDir: String?
  public let persona: String?
  public let taskID: String?
  public let boardItemID: String?
  public let workflowExecutionID: String?
  public let model: String?
  public let effort: String?
  public let allowCustomModel: Bool
  public let recordPermissions: Bool
  public let runtime: String?
  public let argv: [String]
  public let rows: Int
  public let cols: Int
  public let mode: CodexRunMode

  public init(
    family: MobileRelayAgentStartFamily,
    agent: String,
    actor: String,
    role: SessionRole,
    fallbackRole: SessionRole?,
    capabilities: [String],
    name: String?,
    prompt: String?,
    projectDir: String?,
    persona: String?,
    taskID: String?,
    boardItemID: String?,
    workflowExecutionID: String?,
    model: String?,
    effort: String?,
    allowCustomModel: Bool,
    recordPermissions: Bool,
    runtime: String?,
    argv: [String],
    rows: Int,
    cols: Int,
    mode: CodexRunMode
  ) {
    self.family = family
    self.agent = agent
    self.actor = actor
    self.role = role
    self.fallbackRole = fallbackRole
    self.capabilities = capabilities
    self.name = name
    self.prompt = prompt
    self.projectDir = projectDir
    self.persona = persona
    self.taskID = taskID
    self.boardItemID = boardItemID
    self.workflowExecutionID = workflowExecutionID
    self.model = model
    self.effort = effort
    self.allowCustomModel = allowCustomModel
    self.recordPermissions = recordPermissions
    self.runtime = runtime
    self.argv = argv
    self.rows = rows
    self.cols = cols
    self.mode = mode
  }

  func acpAgentStartRequest() throws -> AcpAgentStartRequest {
    let agentName = resolvedAcpAgentName
    guard !agentName.isEmpty else {
      throw MobileRelayCommandExecutionError.missingPayload("agent")
    }
    return AcpAgentStartRequest(
      agent: agentName,
      role: role,
      fallbackRole: fallbackRole,
      capabilities: capabilities,
      name: name,
      prompt: prompt,
      projectDir: projectDir,
      persona: persona,
      taskID: taskID,
      boardItemID: boardItemID,
      workflowExecutionID: workflowExecutionID,
      model: model,
      effort: effort,
      allowCustomModel: allowCustomModel,
      recordPermissions: recordPermissions
    )
  }

  func codexRunRequest() throws -> CodexRunRequest {
    guard let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw MobileRelayCommandExecutionError.missingPayload("prompt")
    }
    return CodexRunRequest(
      actor: actor,
      prompt: prompt,
      mode: mode,
      role: role,
      fallbackRole: fallbackRole,
      capabilities: capabilities.isEmpty ? nil : capabilities,
      name: name,
      persona: persona,
      taskID: taskID,
      boardItemID: boardItemID,
      workflowExecutionID: workflowExecutionID,
      model: model,
      effort: effort,
      allowCustomModel: allowCustomModel
    )
  }

  func terminalStartRequest() -> AgentTuiStartRequest {
    AgentTuiStartRequest(
      runtime: resolvedTerminalRuntime,
      role: role,
      capabilities: capabilities,
      name: name,
      prompt: prompt,
      projectDir: projectDir,
      persona: persona,
      taskID: taskID,
      boardItemID: boardItemID,
      workflowExecutionID: workflowExecutionID,
      model: model,
      effort: effort,
      allowCustomModel: allowCustomModel,
      argv: argv,
      rows: rows,
      cols: cols
    )
  }

  private var resolvedAcpAgentName: String {
    let prefix = "acp:"
    guard agent.lowercased().hasPrefix(prefix) else {
      return agent
    }
    return String(agent.dropFirst(prefix.count))
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var resolvedTerminalRuntime: String {
    if let runtime {
      return runtime
    }
    let normalizedAgent = agent.lowercased()
    for prefix in ["terminal:", "tui:"] where normalizedAgent.hasPrefix(prefix) {
      return String(normalizedAgent.dropFirst(prefix.count))
    }
    if AgentTuiRuntime(rawValue: normalizedAgent) != nil {
      return normalizedAgent
    }
    return AgentTuiRuntime.codex.rawValue
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
  func startAgent(sessionID: String, request: MobileRelayAgentStartRequest) async throws -> String
  func stopAgent(agentID: String) async throws -> String
  func promptAgent(agentID: String, prompt: String) async throws -> String
  func approvePullRequest(_ target: ReviewTarget) async throws -> String
  func labelPullRequest(_ target: ReviewTarget, label: String) async throws -> String
  func rerunPullRequestChecks(_ target: ReviewTarget) async throws -> String
  func mergePullRequest(_ target: ReviewTarget, method: TaskBoardGitHubMergeMethod) async throws
    -> String
  func refreshMobileMirror() async throws -> String
  func refreshReviews(_ target: ReviewTarget?) async throws -> String
  func refreshTaskBoard() async throws -> String
  func refreshSessionTasks(sessionID: String, taskID: String?) async throws -> String
}

public enum MobileRelayRefreshScope: String, Equatable, Sendable {
  case health
  case mobileMirror
  case reviews
  case taskBoard
  case sessionTasks
}

public struct HarnessMonitorClientMobileRelayCommandClient: MobileRelayCommandClient {
  private let client: any HarnessMonitorClientProtocol
  private let reviewsQueryProvider: @Sendable () async -> ReviewsQueryRequest?

  public init(
    client: any HarnessMonitorClientProtocol,
    reviewsQueryProvider: @escaping @Sendable () async -> ReviewsQueryRequest? = { nil }
  ) {
    self.client = client
    self.reviewsQueryProvider = reviewsQueryProvider
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

  public func startAgent(
    sessionID: String,
    request: MobileRelayAgentStartRequest
  ) async throws -> String {
    let snapshot: ManagedAgentSnapshot
    switch request.family {
    case .terminal:
      snapshot = try await client.startManagedTerminalAgent(
        sessionID: sessionID,
        request: request.terminalStartRequest()
      )
    case .codex:
      snapshot = try await client.startManagedCodexAgent(
        sessionID: sessionID,
        request: try request.codexRunRequest()
      )
    case .acp:
      snapshot = try await client.startManagedAcpAgent(
        sessionID: sessionID,
        request: try request.acpAgentStartRequest()
      )
    }
    return "Started \(snapshot.managedAgentID)."
  }

  public func stopAgent(agentID: String) async throws -> String {
    let agent = try await client.managedAgent(agentID: agentID)
    let snapshot: ManagedAgentSnapshot
    switch agent {
    case .terminal:
      snapshot = try await client.stopManagedAgent(agentID: agentID)
    case .codex:
      snapshot = try await client.interruptManagedCodexAgent(agentID: agentID)
    case .acp:
      snapshot = try await client.stopManagedAcpAgent(agentID: agentID)
    }
    return "Stopped \(snapshot.managedAgentID)."
  }

  public func promptAgent(agentID: String, prompt: String) async throws -> String {
    let agent = try await client.managedAgent(agentID: agentID)
    let snapshot: ManagedAgentSnapshot
    switch agent {
    case .terminal:
      snapshot = try await client.sendManagedAgentInput(
        agentID: agentID,
        request: AgentTuiInputRequest(input: .text(prompt.submittedTerminalPrompt))
      )
    case .codex:
      snapshot = try await client.steerManagedCodexAgent(
        agentID: agentID,
        request: CodexSteerRequest(prompt: prompt)
      )
    case .acp:
      snapshot = try await client.promptManagedAcpAgent(agentID: agentID, prompt: prompt)
    }
    return "Prompted \(snapshot.managedAgentID)."
  }

  public func approvePullRequest(_ target: ReviewTarget) async throws -> String {
    let response = try await client.approveReviews(
      request: ReviewsApproveRequest(targets: [target], source: .direct))
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

  public func refreshMobileMirror() async throws -> String {
    async let health = client.health()
    async let sessions = client.sessions()
    let (healthResponse, sessionSummaries) = try await (health, sessions)
    return
      "Refreshed mobile mirror inputs: \(healthResponse.status), \(sessionSummaries.count) session(s)."
  }

  public func refreshReviews(_ target: ReviewTarget?) async throws -> String {
    if let target {
      let response = try await client.refreshReviews(
        request: ReviewsRefreshRequest(targets: [target]))
      return "Refreshed \(response.items.count) review(s)."
    }
    let request: ReviewsQueryRequest?
    if let configuredRequest = await reviewsQueryProvider() {
      request = configuredRequest
    } else {
      request = try await inferredReviewsQueryRequest()
    }
    guard let request else {
      return "Reviews refresh skipped because no repositories are configured."
    }
    let response = try await client.queryReviews(request: request)
    return "Refreshed \(response.items.count) review(s)."
  }

  public func refreshTaskBoard() async throws -> String {
    _ = try await client.syncTaskBoard(request: TaskBoardSyncRequest())
    return "Synced task board."
  }

  public func refreshSessionTasks(sessionID: String, taskID: String?) async throws -> String {
    let detail = try await client.sessionDetail(id: sessionID, scope: nil)
    guard let taskID, !taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return "Refreshed \(detail.tasks.count) session task(s) for \(sessionID)."
    }
    if let task = detail.tasks.first(where: { $0.taskId == taskID }) {
      return "Refreshed session task \(task.title)."
    }
    return "Refreshed session tasks for \(sessionID); task \(taskID) is not mirrored."
  }

  private func inferredReviewsQueryRequest() async throws -> ReviewsQueryRequest? {
    let sessions = try await client.sessions()
    let repositories = MobileRelayGitRepositoryDiscovery.repositories(from: sessions)
    guard !repositories.isEmpty else {
      return nil
    }
    return ReviewsQueryRequest(
      repositories: repositories,
      forceRefresh: true,
      cacheMaxAgeSeconds: MobileRelayReviewsQueryPreferences.minimumCacheMaxAgeSeconds
    )
  }
}

extension String {
  fileprivate var submittedTerminalPrompt: String {
    hasSuffix("\n") ? self : "\(self)\n"
  }
}
