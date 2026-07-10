import Foundation

public final class HarnessMonitorAPIClient: HarnessMonitorClientProtocol {
  static let requestTimeoutInterval: TimeInterval = 15
  static let resourceTimeoutInterval: TimeInterval = 30

  let connection: HarnessMonitorConnection
  let decoder: JSONDecoder
  let encoder: JSONEncoder
  let session: URLSession

  public init(connection: HarnessMonitorConnection, session: URLSession? = nil) {
    self.connection = connection

    if let session {
      self.session = session
    } else {
      let configuration = URLSessionConfiguration.default
      configuration.timeoutIntervalForRequest = Self.requestTimeoutInterval
      configuration.timeoutIntervalForResource = Self.resourceTimeoutInterval
      self.session = HarnessMonitorURLSessionFactory.make(
        configuration: configuration,
        serverTrust: connection.serverTrust
      )
    }

    self.decoder = JSONDecoder()

    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    self.encoder = encoder
  }

  public func health() async throws -> HealthResponse {
    let wire: HealthResponseWire = try await get(
      "/v1/health", decoder: PolicyWireCoding.decoder
    )
    return HealthResponse(wire: wire)
  }

  public func diagnostics() async throws -> DaemonDiagnosticsReport {
    let wire: DaemonDiagnosticsReportWire = try await get(
      "/v1/diagnostics", decoder: PolicyWireCoding.decoder
    )
    return DaemonDiagnosticsReport(wire: wire)
  }

  public func githubStatus() async throws -> GitHubApiDiagnostics {
    let wire: GitHubApiDiagnosticsWire = try await get(
      "/v1/github/status", decoder: PolicyWireCoding.decoder
    )
    return GitHubApiDiagnostics(wire: wire)
  }

  public func stopDaemon() async throws -> DaemonControlResponse {
    let wire: DaemonControlResponseWire = try await post(
      "/v1/daemon/stop", body: EmptyBody(), decoder: PolicyWireCoding.decoder
    )
    return DaemonControlResponse(wire: wire)
  }

  public func reconfigureHostBridge(
    request: HostBridgeReconfigureRequest
  ) async throws -> BridgeStatusReport {
    let wire: BridgeStatusReportWire = try await post(
      "/v1/bridge/reconfigure", body: request, decoder: PolicyWireCoding.decoder
    )
    return BridgeStatusReport(wire: wire)
  }

  public func projects() async throws -> [ProjectSummary] {
    let wire: [ProjectSummaryWire] = try await get(
      "/v1/projects", decoder: PolicyWireCoding.decoder
    )
    return wire.map(ProjectSummary.init(wire:))
  }

  public func sessions() async throws -> [SessionSummary] {
    let wire: [SessionSummaryWire] = try await get(
      "/v1/sessions", decoder: PolicyWireCoding.decoder
    )
    return wire.map(SessionSummary.init(wire:))
  }

  public func sessionDetail(id: String, scope: String?) async throws -> SessionDetail {
    if let scope {
      return try await getSessionDetail("/v1/sessions/\(id)?scope=\(scope)")
    }
    return try await getSessionDetail("/v1/sessions/\(id)")
  }

  public func timeline(sessionID: String) async throws -> [TimelineEntry] {
    try await timeline(sessionID: sessionID, scope: .full)
  }

  public func timelineWindow(sessionID: String, request: TimelineWindowRequest) async throws
    -> TimelineWindowResponse
  {
    let queryItems = timelineWindowQueryItems(for: request)
    let wire: TimelineWindowResponseWire = try await get(
      "/v1/sessions/\(sessionID)/timeline", queryItems: queryItems,
      decoder: PolicyWireCoding.decoder
    )
    return TimelineWindowResponse(wire: wire)
  }

  public func timelineWindow(
    sessionID: String,
    request: TimelineWindowRequest,
    onBatch: @escaping TimelineWindowBatchHandler
  ) async throws -> TimelineWindowResponse {
    let response = try await timelineWindow(sessionID: sessionID, request: request)
    await onBatch(response, 0, 1)
    return response
  }

  public func timeline(sessionID: String, scope: TimelineScope) async throws -> [TimelineEntry] {
    let path =
      scope == .summary
      ? "/v1/sessions/\(sessionID)/timeline?scope=\(scope.rawValue)"
      : "/v1/sessions/\(sessionID)/timeline"
    let wire: [TimelineEntryWire] = try await get(path, decoder: PolicyWireCoding.decoder)
    return wire.map(TimelineEntry.init(wire:))
  }

  public func shutdown() async {
    session.invalidateAndCancel()
  }

  public func globalStream() async -> DaemonPushEventStream {
    stream("/v1/stream")
  }

  public func sessionStream(sessionID: String) async -> DaemonPushEventStream {
    stream("/v1/sessions/\(sessionID)/stream")
  }

  public func createTask(
    sessionID: String,
    request: TaskCreateRequest
  ) async throws -> SessionDetail {
    try await postSessionDetail("/v1/sessions/\(sessionID)/task", body: request)
  }

  public func assignTask(
    sessionID: String,
    taskID: String,
    request: TaskAssignRequest
  ) async throws -> SessionDetail {
    try await postSessionDetail("/v1/sessions/\(sessionID)/tasks/\(taskID)/assign", body: request)
  }

  public func dropTask(
    sessionID: String,
    taskID: String,
    request: TaskDropRequest
  ) async throws -> SessionDetail {
    try await postSessionDetail("/v1/sessions/\(sessionID)/tasks/\(taskID)/drop", body: request)
  }

  public func deleteTask(
    sessionID: String,
    taskID: String,
    request: TaskDeleteRequest
  ) async throws -> SessionDetail {
    try await postSessionDetail("/v1/sessions/\(sessionID)/tasks/\(taskID)", body: request)
  }

  public func updateTaskQueuePolicy(
    sessionID: String,
    taskID: String,
    request: TaskQueuePolicyRequest
  ) async throws -> SessionDetail {
    try await postSessionDetail(
      "/v1/sessions/\(sessionID)/tasks/\(taskID)/queue-policy", body: request
    )
  }

  public func updateTask(
    sessionID: String,
    taskID: String,
    request: TaskUpdateRequest
  ) async throws -> SessionDetail {
    try await postSessionDetail("/v1/sessions/\(sessionID)/tasks/\(taskID)/status", body: request)
  }

  public func checkpointTask(
    sessionID: String,
    taskID: String,
    request: TaskCheckpointRequest
  ) async throws -> SessionDetail {
    try await postSessionDetail(
      "/v1/sessions/\(sessionID)/tasks/\(taskID)/checkpoint", body: request
    )
  }

  public func changeRole(
    sessionID: String,
    agentID: String,
    request: RoleChangeRequest
  ) async throws -> SessionDetail {
    try await postSessionDetail("/v1/sessions/\(sessionID)/agents/\(agentID)/role", body: request)
  }

  public func removeAgent(
    sessionID: String,
    agentID: String,
    request: AgentRemoveRequest
  ) async throws -> SessionDetail {
    try await postSessionDetail("/v1/sessions/\(sessionID)/agents/\(agentID)/remove", body: request)
  }

  public func transferLeader(
    sessionID: String,
    request: LeaderTransferRequest
  ) async throws -> SessionDetail {
    try await postSessionDetail("/v1/sessions/\(sessionID)/leader", body: request)
  }

  public func endSession(
    sessionID: String,
    request: SessionEndRequest
  ) async throws -> SessionDetail {
    try await postSessionDetail("/v1/sessions/\(sessionID)/end", body: request)
  }

  public func archiveSession(
    sessionID: String,
    request: SessionArchiveRequest
  ) async throws -> SessionArchiveResponse {
    let wire: SessionArchiveResponseWire = try await post(
      "/v1/sessions/\(sessionID)/archive",
      body: SessionArchiveRequestWire(request),
      decoder: PolicyWireCoding.decoder
    )
    return SessionArchiveResponse(wire: wire)
  }

  public func sendSignal(
    sessionID: String,
    request: SignalSendRequest
  ) async throws -> SessionDetail {
    try await postSessionDetail("/v1/sessions/\(sessionID)/signal", body: request)
  }

  public func cancelSignal(
    sessionID: String,
    request: SignalCancelRequest
  ) async throws -> SessionDetail {
    try await postSessionDetail("/v1/sessions/\(sessionID)/signal-cancel", body: request)
  }

  public func observeSession(
    sessionID: String,
    request: ObserveSessionRequest
  ) async throws -> SessionDetail {
    try await postSessionDetail("/v1/sessions/\(sessionID)/observe", body: request)
  }

  public func managedAgents(sessionID: String) async throws -> ManagedAgentListResponse {
    let wire: ManagedAgentListResponseWire = try await get(
      "/v1/sessions/\(sessionID)/managed-agents", decoder: PolicyWireCoding.decoder
    )
    return try ManagedAgentListResponse(wire: wire)
  }

  public func managedAgent(agentID: String) async throws -> ManagedAgentSnapshot {
    let wire: ManagedAgentSnapshotWire = try await get(
      "/v1/managed-agents/\(agentID)", decoder: PolicyWireCoding.decoder
    )
    return try ManagedAgentSnapshot(wire: wire)
  }

  public func startManagedTerminalAgent(
    sessionID: String,
    request: AgentTuiStartRequest
  ) async throws -> ManagedAgentSnapshot {
    let wire: ManagedAgentSnapshotWire = try await post(
      "/v1/sessions/\(sessionID)/managed-agents/terminal",
      body: AgentTuiStartRequestWire(request),
      decoder: PolicyWireCoding.decoder
    )
    return try ManagedAgentSnapshot(wire: wire)
  }

  public func startManagedCodexAgent(
    sessionID: String,
    request: CodexRunRequest
  ) async throws -> ManagedAgentSnapshot {
    let wire: ManagedAgentSnapshotWire = try await post(
      "/v1/sessions/\(sessionID)/managed-agents/codex",
      body: CodexRunRequestWire(request),
      decoder: PolicyWireCoding.decoder
    )
    return try ManagedAgentSnapshot(wire: wire)
  }

  public func sendManagedAgentInput(
    agentID: String,
    request: AgentTuiInputRequest
  ) async throws -> ManagedAgentSnapshot {
    let wire: ManagedAgentSnapshotWire = try await post(
      "/v1/managed-agents/\(agentID)/input",
      body: AgentTuiInputRequestWire(request),
      decoder: PolicyWireCoding.decoder
    )
    return try ManagedAgentSnapshot(wire: wire)
  }

  public func resizeManagedAgent(
    agentID: String,
    request: AgentTuiResizeRequest
  ) async throws -> ManagedAgentSnapshot {
    let wire: ManagedAgentSnapshotWire = try await post(
      "/v1/managed-agents/\(agentID)/resize",
      body: AgentTuiResizeRequestWire(request),
      decoder: PolicyWireCoding.decoder
    )
    return try ManagedAgentSnapshot(wire: wire)
  }

  public func stopManagedAgent(agentID: String) async throws -> ManagedAgentSnapshot {
    let wire: ManagedAgentSnapshotWire = try await post(
      "/v1/managed-agents/\(agentID)/stop", body: EmptyBody(), decoder: PolicyWireCoding.decoder
    )
    return try ManagedAgentSnapshot(wire: wire)
  }

  public func steerManagedCodexAgent(
    agentID: String,
    request: CodexSteerRequest
  ) async throws -> ManagedAgentSnapshot {
    let wire: ManagedAgentSnapshotWire = try await post(
      "/v1/managed-agents/\(agentID)/steer",
      body: CodexSteerRequestWire(request),
      decoder: PolicyWireCoding.decoder
    )
    return try ManagedAgentSnapshot(wire: wire)
  }

  public func interruptManagedCodexAgent(agentID: String) async throws -> ManagedAgentSnapshot {
    let wire: ManagedAgentSnapshotWire = try await post(
      "/v1/managed-agents/\(agentID)/interrupt", body: EmptyBody(),
      decoder: PolicyWireCoding.decoder
    )
    return try ManagedAgentSnapshot(wire: wire)
  }

  public func resolveManagedCodexApproval(
    agentID: String,
    approvalID: String,
    request: CodexApprovalDecisionRequest
  ) async throws -> ManagedAgentSnapshot {
    let wire: ManagedAgentSnapshotWire = try await post(
      "/v1/managed-agents/\(agentID)/approvals/\(approvalID)",
      body: CodexApprovalDecisionRequestWire(request),
      decoder: PolicyWireCoding.decoder
    )
    return try ManagedAgentSnapshot(wire: wire)
  }

}
