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
    #expect(objectValue(calls[3].params, key: "agent_id") == .string(terminalSnapshot.tuiId))
    #expect(objectValue(calls[3].params, key: "sequence") != nil)
    #expect(objectValue(calls[7].params, key: "agent_id") == .string(codexSnapshot.runId))
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

  func daemonRPCMethodValues() throws -> Set<String> {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let daemonCatalog =
      repoRoot
      .appendingPathComponent("src/daemon/protocol/api_contract/ws_methods.rs")
    let contents = try String(contentsOf: daemonCatalog, encoding: .utf8)
    let values = contents.split(separator: "\n").compactMap { line -> String? in
      guard line.contains("pub const"),
        let prefixRange = line.range(of: #"&str = ""#)
      else {
        return nil
      }
      let suffix = line[prefixRange.upperBound...]
      guard let end = suffix.firstIndex(of: "\"") else {
        return nil
      }
      return String(suffix[..<end])
    }
    return Set(values)
  }

  private func exerciseBridgeAndManagedAgentMutations(
    transport: WebSocketTransport,
    terminalSnapshot: AgentTuiSnapshot,
    codexSnapshot: CodexRunSnapshot
  ) async throws {
    _ = try await transport.reconfigureHostBridge(
      request: HostBridgeReconfigureRequest(enable: ["codex"])
    )
    _ = try await transport.adoptSession(
      bookmarkID: "bookmark-1",
      sessionRoot: URL(fileURLWithPath: "/tmp/adopt")
    )
    _ = try await transport.startManagedTerminalAgent(
      sessionID: PreviewFixtures.summary.sessionId,
      request: AgentTuiStartRequest(
        runtime: "codex",
        projectDir: PreviewFixtures.summary.projectDir ?? PreviewFixtures.summary.contextRoot
      )
    )
    _ = try await transport.sendManagedAgentInput(
      agentID: terminalSnapshot.tuiId,
      request: try timedSequenceInputRequest()
    )
    _ = try await transport.resizeManagedAgent(
      agentID: terminalSnapshot.tuiId,
      request: AgentTuiResizeRequest(rows: 40, cols: 120)
    )
    _ = try await transport.stopManagedAgent(agentID: terminalSnapshot.tuiId)
    _ = try await transport.startManagedCodexAgent(
      sessionID: PreviewFixtures.summary.sessionId,
      request: CodexRunRequest(actor: "leader-1", prompt: "Investigate", mode: .report)
    )
    _ = try await transport.steerManagedCodexAgent(
      agentID: codexSnapshot.runId,
      request: CodexSteerRequest(prompt: "Continue")
    )
    _ = try await transport.interruptManagedCodexAgent(agentID: codexSnapshot.runId)
    _ = try await transport.resolveManagedCodexApproval(
      agentID: codexSnapshot.runId,
      approvalID: "approval-1",
      request: CodexApprovalDecisionRequest(decision: .accept)
    )
  }

  private func exerciseVoiceMutations(transport: WebSocketTransport) async throws {
    _ = try await transport.startVoiceSession(
      sessionID: PreviewFixtures.summary.sessionId,
      request: VoiceSessionStartRequest(
        actor: "leader-1",
        localeIdentifier: "en_US",
        requestedSinks: [.localDaemon],
        routeTarget: .codexPrompt
      )
    )
    _ = try await transport.appendVoiceAudioChunk(
      voiceSessionID: "voice-1",
      request: VoiceAudioChunkRequest(
        actor: "leader-1",
        chunk: VoiceAudioChunk(
          sequence: 1,
          format: VoiceAudioFormatDescriptor(
            sampleRate: 16_000,
            channelCount: 1,
            commonFormat: "pcmFormatInt16",
            interleaved: false
          ),
          frameCount: 160,
          startedAtSeconds: 0,
          durationSeconds: 0.01,
          audioData: Data([0, 1, 2, 3])
        )
      )
    )
    _ = try await transport.appendVoiceTranscript(
      voiceSessionID: "voice-1",
      request: VoiceTranscriptUpdateRequest(
        actor: "leader-1",
        segment: VoiceTranscriptSegment(
          sequence: 2,
          text: "hello",
          isFinal: true,
          startedAtSeconds: 0,
          durationSeconds: 0.3
        )
      )
    )
    _ = try await transport.finishVoiceSession(
      voiceSessionID: "voice-1",
      request: VoiceSessionFinishRequest(
        actor: "leader-1",
        reason: .completed,
        confirmedText: "hello"
      )
    )
  }

  private func exerciseReviewMutations(transport: WebSocketTransport) async throws {
    _ = try await transport.submitTaskForReview(
      sessionID: PreviewFixtures.summary.sessionId,
      taskID: "task-review",
      request: TaskSubmitForReviewRequest(
        actor: "leader-1",
        summary: "Ready for review",
        suggestedPersona: "reviewer"
      )
    )
    _ = try await transport.claimTaskReview(
      sessionID: PreviewFixtures.summary.sessionId,
      taskID: "task-review",
      request: TaskClaimReviewRequest(actor: "reviewer-1")
    )
    _ = try await transport.submitTaskReview(
      sessionID: PreviewFixtures.summary.sessionId,
      taskID: "task-review",
      request: TaskSubmitReviewRequest(
        actor: "reviewer-1",
        verdict: .requestChanges,
        summary: "Needs one fix",
        points: [ReviewPoint(pointId: "point-1", text: "Tighten validation")]
      )
    )
    _ = try await transport.respondTaskReview(
      sessionID: PreviewFixtures.summary.sessionId,
      taskID: "task-review",
      request: TaskRespondReviewRequest(actor: "worker-1", agreed: ["point-1"], note: "Fixed")
    )
    _ = try await transport.arbitrateTask(
      sessionID: PreviewFixtures.summary.sessionId,
      taskID: "task-review",
      request: TaskArbitrateRequest(
        actor: "leader-1",
        verdict: .approve,
        summary: "Consensus reached"
      )
    )
    _ = try await transport.applyImproverPatch(
      sessionID: PreviewFixtures.summary.sessionId,
      request: ImproverApplyRequest(
        actor: "leader-1",
        issueId: "issue-1",
        target: .skill,
        relPath: "skills/review/SKILL.md",
        newContents: "updated",
        projectDir: "/tmp/project",
        dryRun: true
      )
    )
  }

  private func timedSequenceInputRequest() throws -> AgentTuiInputRequest {
    try AgentTuiInputRequest(
      sequence: AgentTuiInputSequence(
        steps: [
          AgentTuiInputSequenceStep(delayBeforeMs: 0, input: .text("ls")),
          AgentTuiInputSequenceStep(delayBeforeMs: 120, input: .key(.enter)),
        ]
      )
    )
  }

  private func objectValue(_ value: JSONValue?, key: String) -> JSONValue? {
    guard case .object(let object)? = value else {
      return nil
    }
    return object[key]
  }

  private static func jsonValue<Value: Encodable>(_ value: Value) throws -> JSONValue {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let data = try encoder.encode(value)
    return try decoder.decode(JSONValue.self, from: data)
  }
}
