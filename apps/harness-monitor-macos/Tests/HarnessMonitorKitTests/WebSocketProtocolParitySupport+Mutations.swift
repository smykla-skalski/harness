import Foundation
import Testing

@testable import HarnessMonitorKit

extension WebSocketProtocolParityTests {
  func exerciseBridgeAndManagedAgentMutations(
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

  func exerciseVoiceMutations(transport: WebSocketTransport) async throws {
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

  func exerciseReviewMutations(transport: WebSocketTransport) async throws {
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

  func timedSequenceInputRequest() throws -> AgentTuiInputRequest {
    try AgentTuiInputRequest(
      sequence: AgentTuiInputSequence(
        steps: [
          AgentTuiInputSequenceStep(delayBeforeMs: 0, input: .text("ls")),
          AgentTuiInputSequenceStep(delayBeforeMs: 120, input: .key(.enter)),
        ]
      )
    )
  }

  func objectValue(_ value: JSONValue?, key: String) -> JSONValue? {
    guard case .object(let object)? = value else {
      return nil
    }
    return object[key]
  }

  static func jsonValue<Value: Encodable>(_ value: Value) throws -> JSONValue {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let data = try encoder.encode(value)
    return try decoder.decode(JSONValue.self, from: data)
  }
}
