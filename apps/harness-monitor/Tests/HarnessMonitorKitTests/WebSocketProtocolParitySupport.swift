import Foundation
import Testing

@testable import HarnessMonitorKit

extension WebSocketProtocolParityTests {
  func makeRPCTransport(probe: RPCProbe) -> WebSocketTransport {
    let terminalSnapshot = sampleTerminalSnapshot()
    let stoppedTerminalSnapshot = sampleTerminalSnapshot(status: .stopped)
    let codexSnapshot = sampleCodexSnapshot()
    let voiceMutation = VoiceSessionMutationResponse(
      voiceSessionId: "voice-1",
      status: "active"
    )

    return WebSocketTransport(
      connection: HarnessMonitorConnection(endpoint: Self.testEndpoint, token: "test-token"),
      session: session,
      rpcSender: { method, params, _ in
        await probe.record(method: method, params: params)
        switch method {
        case .bridgeReconfigure:
          return try Self.jsonValue(BridgeStatusReport(running: true, capabilities: [:]))
        case .sessionAdopt:
          return .object(["state": try Self.jsonValue(PreviewFixtures.summary)])
        case .managedAgentStartTerminal, .managedAgentInput, .managedAgentResize:
          return try Self.jsonValue(ManagedAgentSnapshot.terminal(terminalSnapshot))
        case .managedAgentStop:
          return try Self.jsonValue(ManagedAgentSnapshot.terminal(stoppedTerminalSnapshot))
        case .managedAgentStartCodex, .managedAgentSteerCodex,
          .managedAgentInterruptCodex, .managedAgentResolveCodexApproval:
          return try Self.jsonValue(ManagedAgentSnapshot.codex(codexSnapshot))
        case .voiceStartSession:
          return try Self.jsonValue(
            VoiceSessionStartResponse(
              voiceSessionId: "voice-1",
              acceptedSinks: [.localDaemon],
              status: "active"
            )
          )
        case .voiceAppendAudio, .voiceAppendTranscript, .voiceFinishSession:
          return try Self.jsonValue(voiceMutation)
        case .taskSubmitForReview, .taskClaimReview, .taskSubmitReview,
          .taskRespondReview, .taskArbitrate, .improverApply:
          return try Self.jsonValue(PreviewFixtures.detail)
        default:
          Issue.record("Unexpected RPC method \(method.rawValue)")
          throw HarnessMonitorAPIError.server(code: 500, message: "unexpected method")
        }
      }
    )
  }

  func makeQueryRPCTransport(probe: RPCProbe) -> WebSocketTransport {
    let codexSnapshot = sampleCodexSnapshot()

    return WebSocketTransport(
      connection: HarnessMonitorConnection(endpoint: Self.testEndpoint, token: "test-token"),
      session: session,
      rpcSender: { method, params, _ in
        await probe.record(method: method, params: params)
        switch method {
        case .githubStatus:
          return try Self.jsonValue(PreviewHarnessClient.previewGitHubApiDiagnostics)
        case .sessionManagedAgents:
          return try Self.jsonValue(
            ManagedAgentListResponse(agents: [.codex(codexSnapshot)])
          )
        case .managedAgentDetail:
          return try Self.jsonValue(ManagedAgentSnapshot.codex(codexSnapshot))
        case .managedAgentAcpInspect:
          return try Self.jsonValue(AcpAgentInspectResponse(agents: []))
        case .managedAgentAcpTranscript:
          return try Self.jsonValue(AcpTranscriptResponse(entries: []))
        default:
          Issue.record("Unexpected RPC method \(method.rawValue)")
          throw HarnessMonitorAPIError.server(code: 500, message: "unexpected method")
        }
      }
    )
  }

  func makeSessionAgentMutationRPCTransport(probe: RPCProbe) -> WebSocketTransport {
    WebSocketTransport(
      connection: HarnessMonitorConnection(endpoint: Self.testEndpoint, token: "test-token"),
      session: session,
      rpcSender: { method, params, _ in
        await probe.record(method: method, params: params)
        switch method {
        case .agentChangeRole, .agentRemove:
          return try Self.jsonValue(PreviewFixtures.detail)
        default:
          Issue.record("Unexpected RPC method \(method.rawValue)")
          throw HarnessMonitorAPIError.server(code: 500, message: "unexpected method")
        }
      }
    )
  }

  func exerciseParityMutations(
    transport: WebSocketTransport,
    terminalSnapshot: AgentTuiSnapshot,
    codexSnapshot: CodexRunSnapshot
  ) async throws {
    try await exerciseBridgeAndManagedAgentMutations(
      transport: transport,
      terminalSnapshot: terminalSnapshot,
      codexSnapshot: codexSnapshot
    )
    try await exerciseVoiceMutations(transport: transport)
    try await exerciseReviewMutations(transport: transport)
  }

  func assertExpectedMethods(_ calls: [RPCProbe.Call]) {
    #expect(
      calls.map(\.method)
        == [
          .bridgeReconfigure,
          .sessionAdopt,
          .managedAgentStartTerminal,
          .managedAgentInput,
          .managedAgentResize,
          .managedAgentStop,
          .managedAgentStartCodex,
          .managedAgentSteerCodex,
          .managedAgentInterruptCodex,
          .managedAgentResolveCodexApproval,
          .voiceStartSession,
          .voiceAppendAudio,
          .voiceAppendTranscript,
          .voiceFinishSession,
          .taskSubmitForReview,
          .taskClaimReview,
          .taskSubmitReview,
          .taskRespondReview,
          .taskArbitrate,
          .improverApply,
        ]
    )
  }

  func assertExpectedParameters(
    calls: [RPCProbe.Call],
    terminalSnapshot: AgentTuiSnapshot,
    codexSnapshot: CodexRunSnapshot
  ) {
    #expect(objectValue(calls[0].params, key: "enable") == .array([.string("codex")]))
    #expect(objectValue(calls[1].params, key: "bookmark_id") == .string("bookmark-1"))
    #expect(
      objectValue(calls[2].params, key: "session_id") == .string(PreviewFixtures.summary.sessionId)
    )
    #expect(
      objectValue(calls[3].params, key: "managed_agent_id") == .string(terminalSnapshot.tuiId)
    )
    #expect(objectValue(calls[3].params, key: "agent_id") == nil)
    #expect(objectValue(calls[3].params, key: "sequence") != nil)
    #expect(
      objectValue(calls[6].params, key: "session_id") == .string(PreviewFixtures.summary.sessionId)
    )
    #expect(objectValue(calls[6].params, key: "prompt") == .string("Investigate"))
    #expect(objectValue(calls[6].params, key: "mode") == .string("report"))
    #expect(objectValue(calls[6].params, key: "actor") == .string("leader-1"))
    #expect(
      objectValue(calls[7].params, key: "managed_agent_id") == .string(codexSnapshot.runId)
    )
    #expect(objectValue(calls[7].params, key: "prompt") == .string("Continue"))
    #expect(objectValue(calls[7].params, key: "agent_id") == nil)
    #expect(
      objectValue(calls[8].params, key: "managed_agent_id") == .string(codexSnapshot.runId)
    )
    #expect(objectValue(calls[8].params, key: "agent_id") == nil)
    #expect(
      objectValue(calls[9].params, key: "managed_agent_id") == .string(codexSnapshot.runId)
    )
    #expect(objectValue(calls[9].params, key: "approval_id") == .string("approval-1"))
    #expect(objectValue(calls[9].params, key: "decision") == .string("accept"))
    #expect(objectValue(calls[9].params, key: "agent_id") == nil)
    #expect(
      objectValue(calls[10].params, key: "session_id")
        == .string(PreviewFixtures.summary.sessionId)
    )
    #expect(objectValue(calls[11].params, key: "voice_session_id") == .string("voice-1"))
    #expect(objectValue(calls[14].params, key: "task_id") == .string("task-review"))
    #expect(objectValue(calls[14].params, key: "suggested_persona") == .string("reviewer"))
    #expect(objectValue(calls[15].params, key: "actor") == .string("reviewer-1"))
    #expect(objectValue(calls[16].params, key: "verdict") == .string("request_changes"))
    #expect(objectValue(calls[17].params, key: "agreed") == .array([.string("point-1")]))
    #expect(objectValue(calls[18].params, key: "summary") == .string("Consensus reached"))
    #expect(objectValue(calls[19].params, key: "issue_id") == .string("issue-1"))
    #expect(objectValue(calls[19].params, key: "dry_run") == .bool(true))
  }

  func exerciseParityQueries(transport: WebSocketTransport) async throws {
    _ = try await transport.githubStatus()
    _ = try await transport.managedAgents(sessionID: PreviewFixtures.summary.sessionId)
    _ = try await transport.managedAgent(agentID: "codex-run-1")
    _ = try await transport.acpInspect(sessionID: PreviewFixtures.summary.sessionId)
    _ = try await transport.acpTranscript(sessionID: PreviewFixtures.summary.sessionId)
  }

  func assertExpectedQueryParameters(_ calls: [RPCProbe.Call]) {
    #expect(
      calls.map(\.method)
        == [
          .githubStatus,
          .sessionManagedAgents,
          .managedAgentDetail,
          .managedAgentAcpInspect,
          .managedAgentAcpTranscript,
        ]
    )
    #expect(calls[0].params == nil)
    #expect(
      objectValue(calls[1].params, key: "session_id") == .string(PreviewFixtures.summary.sessionId)
    )
    #expect(objectValue(calls[2].params, key: "managed_agent_id") == .string("codex-run-1"))
    #expect(
      objectValue(calls[3].params, key: "session_id") == .string(PreviewFixtures.summary.sessionId)
    )
    #expect(
      objectValue(calls[4].params, key: "session_id") == .string(PreviewFixtures.summary.sessionId)
    )
  }

  func exerciseSessionAgentMutations(transport: WebSocketTransport) async throws {
    _ = try await transport.changeRole(
      sessionID: PreviewFixtures.summary.sessionId,
      agentID: "worker-1",
      request: RoleChangeRequest(actor: "leader-1", role: .reviewer)
    )
    _ = try await transport.removeAgent(
      sessionID: PreviewFixtures.summary.sessionId,
      agentID: "worker-1",
      request: AgentRemoveRequest(actor: "leader-1")
    )
  }

  func assertExpectedSessionAgentMutationParameters(_ calls: [RPCProbe.Call]) {
    #expect(calls.map(\.method) == [.agentChangeRole, .agentRemove])
    for call in calls {
      #expect(
        objectValue(call.params, key: "session_id") == .string(PreviewFixtures.summary.sessionId)
      )
      #expect(objectValue(call.params, key: "session_agent_id") == .string("worker-1"))
    }
  }

  func sampleTerminalSnapshot(status: AgentTuiStatus = .running) -> AgentTuiSnapshot {
    AgentTuiSnapshot(
      tuiId: "tui-1",
      sessionId: PreviewFixtures.summary.sessionId,
      agentId: "terminal-agent-1",
      runtime: "codex",
      status: status,
      argv: ["codex"],
      projectDir: PreviewFixtures.summary.projectDir ?? PreviewFixtures.summary.contextRoot,
      size: AgentTuiSize(rows: 24, cols: 80),
      screen: AgentTuiScreenSnapshot(
        rows: 24,
        cols: 80,
        cursorRow: 1,
        cursorCol: 1,
        text: "ready"
      ),
      transcriptPath: "/tmp/tui-1.log",
      exitCode: nil,
      signal: nil,
      error: nil,
      createdAt: "2026-04-22T10:00:00Z",
      updatedAt: "2026-04-22T10:00:01Z"
    )
  }

  func sampleCodexSnapshot() -> CodexRunSnapshot {
    CodexRunSnapshot(
      runId: "codex-run-1",
      sessionId: PreviewFixtures.summary.sessionId,
      projectDir: PreviewFixtures.summary.projectDir ?? PreviewFixtures.summary.contextRoot,
      threadId: "thread-1",
      turnId: "turn-1",
      mode: .report,
      status: .running,
      prompt: "Investigate websocket parity",
      latestSummary: "running",
      finalMessage: nil,
      error: nil,
      pendingApprovals: [],
      createdAt: "2026-04-22T10:00:00Z",
      updatedAt: "2026-04-22T10:00:01Z"
    )
  }

}
