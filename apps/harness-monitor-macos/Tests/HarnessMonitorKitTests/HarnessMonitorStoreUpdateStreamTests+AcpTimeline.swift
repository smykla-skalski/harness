import Testing

@testable import HarnessMonitorKit

extension HarnessMonitorStoreUpdateStreamTests {
  @Test("ACP event push appends selected session timeline")
  func acpEventPushAppendsSelectedSessionTimeline() async throws {
    let client = RecordingHarnessClient()
    let summary = makeSession(
      .init(
        sessionId: "sess-acp-events",
        context: "ACP timeline",
        status: .active,
        leaderId: "leader-acp",
        observeId: nil,
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-acp",
      workerName: "Worker ACP"
    )
    let initialTimeline = makeTimelineEntries(
      sessionID: summary.sessionId,
      agentID: "worker-acp",
      summary: "Initial timeline"
    )
    client.configureSessions(
      summaries: [summary],
      detailsByID: [summary.sessionId: detail],
      timelinesBySessionID: [summary.sessionId: initialTimeline]
    )
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client)
    )

    await store.bootstrap()
    await store.selectSession(summary.sessionId)
    store.applySessionPushEvent(
      DaemonPushEvent(
        recordedAt: "2026-04-28T00:00:30Z",
        sessionId: summary.sessionId,
        kind: .acpEvents(
          AcpEventBatchPayload(
            acpId: "acp-1",
            sessionId: summary.sessionId,
            rawCount: 1,
            events: [
              AcpConversationEvent(
                timestamp: "2026-04-28T00:00:20Z",
                sequence: 9,
                kind: .object([
                  "type": .string("tool_invocation"),
                  "tool_name": .string("Read"),
                  "category": .string("read"),
                  "input": .object(["path": .string("README.md")]),
                  "invocation_id": .string("call-read"),
                ]),
                agent: "copilot",
                sessionId: summary.sessionId
              )
            ]
          )
        )
      )
    )

    let acpEntry = try #require(
      store.timeline.first(where: { entry in
        guard entry.kind == "tool_invocation",
          let payloadObject = jsonObject(from: entry.payload),
          let timelineObject = jsonObject(from: payloadObject["tool_call_timeline"])
        else {
          return false
        }
        return jsonString(from: timelineObject["tool_call_id"]) == "call-read"
      })
    )
    #expect(acpEntry.kind == "tool_invocation")
    #expect(acpEntry.summary == "copilot invoked Read")
    #expect(store.timelineWindow?.totalCount == 2)

    store.stopAllStreams()
  }

  @Test("ACP event push precomputes timeline attribution metadata")
  func acpEventPushPrecomputesTimelineAttributionMetadata() throws {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-events"
    store.applyAcpAgent(
      makeAcpSnapshot(acpID: "acp-1", sessionID: "sess-acp-events", pendingBatches: []))
    store.acpAgentDescriptorsByID["copilot"] = AcpAgentDescriptor(
      id: "copilot",
      displayName: "Copilot",
      capabilities: ["filesystem", "terminal"],
      launchCommand: "copilot",
      launchArgs: [],
      envPassthrough: [],
      modelCatalog: nil,
      installHint: nil,
      doctorProbe: AcpDoctorProbe(command: "copilot", args: ["doctor"])
    )

    store.applySessionPushEvent(
      DaemonPushEvent(
        recordedAt: "2026-04-28T00:00:30Z",
        sessionId: "sess-acp-events",
        kind: .acpEvents(
          AcpEventBatchPayload(
            acpId: "acp-1",
            sessionId: "sess-acp-events",
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
                sessionId: "sess-acp-events"
              )
            ]
          )
        )
      )
    )

    let entry = try #require(store.timeline.first)
    let payloadObject = try #require(jsonObject(from: entry.payload))
    let toolCallTimeline = try #require(jsonObject(from: payloadObject["tool_call_timeline"]))
    let capabilityTags: [String] =
      if case .array(let values)? = toolCallTimeline["capability_tags"] {
        values.compactMap { value in
          if case .string(let string) = value { string } else { nil }
        }
      } else { [] }

    #expect(jsonString(from: toolCallTimeline["tool_call_id"]) == "call-read")
    #expect(jsonString(from: toolCallTimeline["acp_agent_id"]) == "acp-1")
    #expect(jsonString(from: toolCallTimeline["agent_id"]) == "copilot")
    #expect(jsonString(from: toolCallTimeline["agent_display_name"]) == "Copilot")
    #expect(jsonNumber(from: toolCallTimeline["sequence"]) == 9)
    #expect(capabilityTags == ["filesystem", "terminal"])
  }

  @Test("ACP event push preserves event agent when no descriptor is cached")
  func acpEventPushPreservesEventAgentWhenNoDescriptorIsCached() throws {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-events"
    store.applySessionPushEvent(
      DaemonPushEvent(
        recordedAt: "2026-04-28T00:00:30Z",
        sessionId: "sess-acp-events",
        kind: .acpEvents(
          AcpEventBatchPayload(
            acpId: "acp-1",
            sessionId: "sess-acp-events",
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
                sessionId: "sess-acp-events"
              )
            ]
          )
        )
      )
    )
    let entry = try #require(store.timeline.first)
    let payloadObject = try #require(jsonObject(from: entry.payload))
    let toolCallTimeline = try #require(jsonObject(from: payloadObject["tool_call_timeline"]))
    #expect(jsonString(from: toolCallTimeline["agent_id"]) == "copilot")
    #expect(jsonString(from: toolCallTimeline["agent_display_name"]) == "copilot")
  }
}
