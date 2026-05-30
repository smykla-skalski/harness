import Foundation
import Testing

@testable import HarnessMonitorKit

extension HarnessMonitorStoreUpdateStreamTests {
  @Test("ACP transcript rows reattribute when a live snapshot arrives after the event")
  func acpTranscriptRowsReattributeWhenSnapshotArrivesLater() async throws {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-reattribute"

    store.applySessionPushEvent(makeAssistantTextPush(sessionID: "sess-acp-reattribute"))
    await store.waitForAcpTimelineIdle()

    #expect(store.timeline.first?.agentId == "copilot")
    #expect(store.timeline(forAgent: "worker-acp").isEmpty)
    #expect(store.acpTranscript(forAgent: "worker-acp").isEmpty)

    store.applyAcpAgent(
      makeAcpSnapshot(
        acpID: "acp-1",
        sessionID: "sess-acp-reattribute",
        agentID: "worker-acp",
        displayName: "Worker ACP",
        pendingBatches: []
      )
    )
    await store.waitForAcpTimelineIdle()

    let entry = try #require(store.timeline.first)
    #expect(entry.entryId == "acp-worker-acp-assistant_text-9")
    #expect(entry.agentId == "worker-acp")
    #expect(entry.summary == "Transcript line from ACP.")
    #expect(store.timeline(forAgent: "worker-acp").map(\.entryId) == [entry.entryId])
    #expect(store.acpTranscript(forAgent: "worker-acp").map(\.entryId) == [entry.entryId])
  }

  @Test("ACP transcript rows reattribute when refresh reconciles ACP agents after the event")
  func acpTranscriptRowsReattributeWhenRefreshArrivesLater() async throws {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-refresh"

    store.applySessionPushEvent(makeAssistantTextPush(sessionID: "sess-acp-refresh"))
    await store.waitForAcpTimelineIdle()

    store.replaceAcpAgents(
      AcpAgentsReconciledPayload(
        sessionId: "sess-acp-refresh",
        agents: [
          makeAcpSnapshot(
            acpID: "acp-1",
            sessionID: "sess-acp-refresh",
            agentID: "worker-acp",
            displayName: "Worker ACP",
            pendingBatches: []
          )
        ],
        inspect: nil
      )
    )
    await store.waitForAcpTimelineIdle()

    let entry = try #require(store.timeline.first)
    #expect(entry.entryId == "acp-worker-acp-assistant_text-9")
    #expect(entry.agentId == "worker-acp")
    #expect(entry.summary == "Transcript line from ACP.")
    #expect(store.timeline(forAgent: "worker-acp").map(\.entryId) == [entry.entryId])
    #expect(store.acpTranscript(forAgent: "worker-acp").map(\.entryId) == [entry.entryId])
  }

  @Test("ACP tool rows repair their visible actor label after delayed attribution")
  func acpToolRowsRepairSummaryWhenSnapshotArrivesLater() async throws {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-tool-reattribute"

    store.applySessionPushEvent(makeToolInvocationPush(sessionID: "sess-acp-tool-reattribute"))
    await store.waitForAcpTimelineIdle()
    #expect(store.timeline.first?.summary == "copilot invoked Read")

    store.applyAcpAgent(
      makeAcpSnapshot(
        acpID: "acp-1",
        sessionID: "sess-acp-tool-reattribute",
        agentID: "worker-acp",
        displayName: "Worker ACP",
        pendingBatches: []
      )
    )
    await store.waitForAcpTimelineIdle()

    let entry = try #require(store.timeline.first)
    #expect(entry.entryId == "acp-worker-acp-tool_invocation-9")
    #expect(entry.agentId == "worker-acp")
    #expect(entry.summary == "Worker ACP invoked Read")
  }

  private func makeAssistantTextPush(sessionID: String) -> DaemonPushEvent {
    DaemonPushEvent(
      recordedAt: "2026-04-28T00:00:30Z",
      sessionId: sessionID,
      kind: .acpEvents(
        AcpEventBatchPayload(
          acpId: "acp-1",
          sessionId: sessionID,
          rawCount: 1,
          events: [
            AcpConversationEvent(
              timestamp: "2026-04-28T00:00:20Z",
              sequence: 9,
              kind: .object([
                "type": .string("assistant_text"),
                "content": .string("Transcript line from ACP."),
              ]),
              agent: "copilot",
              sessionId: sessionID
            )
          ]
        )
      )
    )
  }

  private func makeToolInvocationPush(sessionID: String) -> DaemonPushEvent {
    DaemonPushEvent(
      recordedAt: "2026-04-28T00:00:30Z",
      sessionId: sessionID,
      kind: .acpEvents(
        AcpEventBatchPayload(
          acpId: "acp-1",
          sessionId: sessionID,
          rawCount: 1,
          events: [
            AcpConversationEvent(
              timestamp: "2026-04-28T00:00:20Z",
              sequence: 9,
              kind: .object([
                "type": .string("tool_invocation"),
                "tool_name": .string("Read"),
                "invocation_id": .string("call-read"),
              ]),
              agent: "copilot",
              sessionId: sessionID
            )
          ]
        )
      )
    )
  }
}
