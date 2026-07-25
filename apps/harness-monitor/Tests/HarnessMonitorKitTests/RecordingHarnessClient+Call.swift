import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  enum Call: Equatable {
    case assignTask(sessionID: String, taskID: String, agentID: String, actor: String)
    case changeRole(sessionID: String, agentID: String, role: SessionRole, actor: String)
    case checkpointTask(
      sessionID: String,
      taskID: String,
      summary: String,
      progress: Int,
      actor: String
    )
    case submitTaskForReview(
      sessionID: String,
      taskID: String,
      actor: String,
      summary: String?,
      suggestedPersona: String?
    )
    case claimTaskReview(sessionID: String, taskID: String, actor: String)
    case submitTaskReview(
      sessionID: String,
      taskID: String,
      actor: String,
      verdict: ReviewVerdict,
      summary: String,
      points: [ReviewPoint]
    )
    case respondTaskReview(
      sessionID: String,
      taskID: String,
      actor: String,
      agreed: [String],
      disputed: [String],
      note: String?
    )
    case arbitrateTask(
      sessionID: String,
      taskID: String,
      actor: String,
      verdict: ReviewVerdict,
      summary: String
    )
    case applyImproverPatch(
      sessionID: String,
      actor: String,
      issueID: String,
      target: ImproverTarget,
      relPath: String,
      newContents: String,
      projectDir: String,
      dryRun: Bool
    )
    case reconfigureHostBridge(enable: [String], disable: [String], force: Bool)
    case createTask(
      sessionID: String,
      title: String,
      context: String?,
      severity: TaskSeverity,
      actor: String
    )
    case deleteTask(sessionID: String, taskID: String, actor: String)
    case dropTask(
      sessionID: String,
      taskID: String,
      target: TaskDropTarget,
      queuePolicy: TaskQueuePolicy,
      actor: String
    )
    case interruptCodexRun(runID: String)
    case startAgentTui(
      sessionID: String,
      runtime: String,
      name: String?,
      prompt: String?,
      projectDir: String?,
      persona: String?,
      argv: [String],
      rows: Int,
      cols: Int
    )
    case startAcpAgent(
      sessionID: String,
      agentID: String,
      role: SessionRole,
      fallbackRole: SessionRole?,
      capabilities: [String],
      name: String?,
      prompt: String?,
      projectDir: String?,
      persona: String?,
      model: String?,
      effort: String?,
      allowCustomModel: Bool,
      recordPermissions: Bool
    )
    case sendAgentTuiInput(tuiID: String, request: AgentTuiInputRequest)
    case resizeAgentTui(tuiID: String, rows: Int, cols: Int)
    case stopAgentTui(tuiID: String)
    case adoptSession(bookmarkID: String?, sessionRoot: URL)
    case startSession(projectDir: String, baseRef: String?)
    case endSession(sessionID: String, actor: String)
    case removeSession(sessionID: String, actor: String)
    case observeSession(sessionID: String, actor: String)
    case removeAgent(sessionID: String, agentID: String, actor: String)
    case resolveCodexApproval(
      runID: String,
      approvalID: String,
      decision: CodexApprovalDecision
    )
    case resolveAcpPermission(
      agentID: String,
      batchID: String,
      decision: AcpPermissionDecision
    )
    case sendSignal(sessionID: String, agentID: String, command: String, actor: String)
    case cancelSignal(sessionID: String, agentID: String, signalID: String, actor: String)
    case startCodexRun(
      sessionID: String,
      prompt: String,
      mode: CodexRunMode,
      actor: String?,
      resumeThreadID: String?
    )
    case steerCodexRun(runID: String, prompt: String)
    case startVoiceSession(
      sessionID: String,
      localeIdentifier: String,
      sinks: [VoiceProcessingSink],
      routeTarget: VoiceRouteTarget,
      requiresConfirmation: Bool,
      remoteProcessorURL: String?,
      actor: String
    )
    case appendVoiceAudioChunk(voiceSessionID: String, sequence: UInt64, actor: String)
    case appendVoiceTranscript(voiceSessionID: String, sequence: UInt64, actor: String)
    case finishVoiceSession(
      voiceSessionID: String,
      reason: VoiceSessionFinishReason,
      confirmedText: String?,
      actor: String
    )
    case transferLeader(sessionID: String, newLeaderID: String, reason: String?, actor: String)
    case startTaskBoardOrchestrator
    case stopTaskBoardOrchestrator
    case runTaskBoardOrchestratorOnce(
      itemID: String?,
      dryRun: Bool?,
      status: TaskBoardStatus?,
      projectDir: String?
    )
    case forceCancelTaskBoardAutomation(request: TaskBoardAutomationForceCancelRequest)
    case dispatchTaskBoard(
      dryRun: Bool,
      status: TaskBoardStatus?,
      itemID: String?,
      projectDir: String?,
      actor: String?
    )
    case deliverTaskBoardDispatch(itemID: String, dryRun: Bool)
    case evaluateTaskBoard(
      dryRun: Bool,
      status: TaskBoardStatus?,
      itemID: String?
    )
    case createTaskBoardItem(
      title: String,
      priority: TaskBoardPriority,
      status: TaskBoardStatus?
    )
    case updateTaskBoardItem(
      id: String,
      status: TaskBoardStatus?
    )
    case setTaskBoardItemPosition(id: String, status: TaskBoardStatus, lanePosition: UInt32)
    case resetTaskBoardItemPosition(id: String)
    case deleteTaskBoardItem(id: String)
    case beginTaskBoardPlan(id: String)
    case submitTaskBoardPlan(id: String, summary: String)
    case approveTaskBoardPlan(id: String, approvedBy: String, approvedAt: String?)
    case revokeTaskBoardPlan(id: String, actor: String?)
    case updateTaskBoardOrchestratorSettings(
      stepMode: Bool?,
      policyVersion: String?,
      clearProjectDir: Bool,
      clearDispatchStatusFilter: Bool
    )
    case updateTaskBoardGitRuntimeConfig(overrideCount: Int)
    case syncTaskBoardGitRuntimeKeyMaterial(overrideCount: Int)
    case syncTaskBoardGitHubTokens(
      globalTokenConfigured: Bool,
      repositoryTokenCount: Int
    )
    case syncTaskBoardOpenRouterToken(tokenConfigured: Bool)
    case taskBoardGitIdentityDefaults
    case verifyTaskBoardGitSigning(repository: String?)
    case prepareTaskBoardSecretHandoff
    case ackTaskBoardSecretHandoff(migrationID: String, digest: String)
    case syncTaskBoard(
      direction: TaskBoardExternalSyncDirection,
      dryRun: Bool,
      status: TaskBoardStatus?,
      provider: TaskBoardExternalProvider?
    )
    case auditTaskBoard(status: TaskBoardStatus?)
    case taskBoardProjects(status: TaskBoardStatus?)
    case taskBoardMachines(status: TaskBoardStatus?)
    case taskBoardHostLocal
    case taskBoardHostList
    case setTaskBoardHostProjectTypes(projectTypes: [String])
    case savePolicyPipelineDraft(revision: UInt64)
    case simulatePolicyPipeline
    case promotePolicyPipeline(revision: UInt64)
    case makeLivePolicyPipeline(revision: UInt64)
    case updateTaskQueuePolicy(
      sessionID: String,
      taskID: String,
      queuePolicy: TaskQueuePolicy,
      actor: String
    )
    case updateTask(
      sessionID: String,
      taskID: String,
      status: TaskStatus,
      note: String?,
      actor: String
    )
  }

  enum ReadCall {
    case health
    case transportLatency
    case diagnostics
    case projects
    case sessions
    case taskBoardItems(TaskBoardStatus?)
    case sessionDetail(String)
    case timeline(String)
    case timelineWindow(String)
    case acpTranscript(String)
    case codexTranscript(String)
    case taskBoardOrchestratorStatus
    case taskBoardOrchestratorSettings
    case taskBoardGitRuntimeConfig
    case policyCanvasWorkspace
    case policyPipeline
    case policyPipelineAudit
  }
}
