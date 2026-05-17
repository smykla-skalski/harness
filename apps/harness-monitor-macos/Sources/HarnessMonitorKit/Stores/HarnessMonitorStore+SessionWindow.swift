import Foundation

extension HarnessMonitorStore {
  public func replacePreviewTimeline(
    sessionID: String,
    entries: [TimelineEntry]
  ) async -> Bool {
    guard
      let previewClient = client as? PreviewHarnessClient,
      let updatedSummary = await previewClient.replaceTimeline(
        sessionID: sessionID,
        entries: entries
      )
    else {
      return false
    }

    applySessionSummaryUpdate(updatedSummary)
    return true
  }

  public func sessionWindowSnapshot(
    sessionID: String
  ) async -> HarnessMonitorSessionWindowSnapshot? {
    guard !Task.isCancelled else { return nil }
    if connectionState == .online, let client {
      if let liveSnapshot = await loadLiveSessionWindowSnapshot(
        sessionID: sessionID,
        client: client
      ) {
        return liveSnapshot
      }
      guard !Task.isCancelled else { return nil }
    }

    if let cached = await loadCachedSessionDetail(sessionID: sessionID) {
      guard !Task.isCancelled else { return nil }
      let cachedTranscript = cached.transcript ?? []
      return HarnessMonitorSessionWindowSnapshot(
        summary: cached.detail.session,
        detail: cached.detail,
        acpAgents: [],
        acpInspectSample: nil,
        timeline: cached.timeline,
        transcript: cachedTranscript,
        transcriptSource: cached.transcriptSource
          ?? (cachedTranscript.isEmpty ? .derived : .cache),
        timelineWindow: cached.timelineWindow,
        source: .cache
      )
    }

    guard !Task.isCancelled else { return nil }
    guard let summary = sessionIndex.sessionSummary(for: sessionID) else {
      return nil
    }
    return HarnessMonitorSessionWindowSnapshot(
      summary: summary,
      detail: nil,
      acpAgents: [],
      acpInspectSample: nil,
      timeline: [],
      transcript: [],
      transcriptSource: .derived,
      timelineWindow: nil,
      source: .catalog
    )
  }

  private func loadLiveSessionWindowSnapshot(
    sessionID: String,
    client: any HarnessMonitorClientProtocol
  ) async -> HarnessMonitorSessionWindowSnapshot? {
    do {
      let detailScope = activeTransport == .webSocket ? "core" : nil
      async let detailTask = client.sessionDetail(id: sessionID, scope: detailScope)
      async let timelineWindowTask = try? client.timelineWindow(
        sessionID: sessionID,
        request: .latest(limit: Self.initialSelectedTimelineWindowLimit)
      ) { _, _, _ in }
      async let acpAgentsTask = loadSessionWindowAcpAgents(
        sessionID: sessionID,
        client: client
      )
      async let acpInspectTask = loadSessionWindowAcpInspectSample(
        sessionID: sessionID,
        client: client
      )
      async let taskBoardItemsTask = loadSessionWindowTaskBoardItems(client: client)
      async let transcriptTask = loadSessionWindowTranscriptResponse(
        sessionID: sessionID,
        client: client
      )
      async let codexTranscriptTask = loadSessionWindowCodexTranscriptResponse(
        sessionID: sessionID,
        client: client
      )

      let detail = try await detailTask
      guard !Task.isCancelled else { return nil }
      let timelineWindow = await timelineWindowTask
      let acpAgents = await acpAgentsTask
      let acpInspectSample = await acpInspectTask
      let taskBoardItems = await taskBoardItemsTask
      let transcriptResponse = await transcriptTask
      let codexTranscriptResponse = await codexTranscriptTask
      guard !Task.isCancelled else { return nil }
      let transcript = await sessionWindowPresentationWorker.resolveTranscript(
        detail: detail,
        timeline: timelineWindow?.entries ?? [],
        acpTranscript: transcriptResponse,
        codexTranscript: codexTranscriptResponse
      )
      let snapshot = HarnessMonitorSessionWindowSnapshot(
        summary: detail.session,
        detail: detail,
        acpAgents: acpAgents,
        acpInspectSample: acpInspectSample,
        taskBoardItems: taskBoardItems,
        timeline: timelineWindow?.entries ?? [],
        transcript: transcript.entries,
        transcriptSource: transcript.source,
        timelineWindow: timelineWindow,
        source: .live
      )
      scheduleSessionDetailCacheWrite(
        detail,
        timeline: snapshot.timeline,
        transcript: snapshot.transcript,
        transcriptSource: snapshot.transcriptSource,
        timelineWindow: snapshot.timelineWindow
      )
      return snapshot
    } catch {
      guard !(error is CancellationError) else {
        return nil
      }
      return nil
    }
  }

  private func loadSessionWindowTaskBoardItems(
    client: any HarnessMonitorClientProtocol
  ) async -> [TaskBoardItem]? {
    do {
      return try await client.taskBoardItems(status: nil)
    } catch is CancellationError {
      return nil
    } catch {
      return nil
    }
  }

  private func loadSessionWindowTranscriptResponse(
    sessionID: String,
    client: any HarnessMonitorClientProtocol
  ) async -> AcpTranscriptResponse? {
    do {
      return try await client.acpTranscript(sessionID: sessionID)
    } catch is CancellationError {
      return nil
    } catch {
      return nil
    }
  }

  private func loadSessionWindowCodexTranscriptResponse(
    sessionID: String,
    client: any HarnessMonitorClientProtocol
  ) async -> CodexTranscriptResponse? {
    do {
      return try await client.codexTranscript(sessionID: sessionID)
    } catch is CancellationError {
      return nil
    } catch {
      return nil
    }
  }

  public func refreshSessionWindowManagedTranscript(
    sessionID: String,
    snapshot: HarnessMonitorSessionWindowSnapshot
  ) async -> HarnessMonitorSessionWindowSnapshot? {
    guard connectionState == .online, let client, let detail = snapshot.detail else {
      return nil
    }

    async let transcriptTask = loadSessionWindowTranscriptResponse(
      sessionID: sessionID,
      client: client
    )
    async let codexTranscriptTask = loadSessionWindowCodexTranscriptResponse(
      sessionID: sessionID,
      client: client
    )

    let transcriptResponse = await transcriptTask
    let codexTranscriptResponse = await codexTranscriptTask
    guard transcriptResponse != nil || codexTranscriptResponse != nil else {
      return nil
    }

    let transcript = await sessionWindowPresentationWorker.resolveTranscript(
      detail: detail,
      timeline: snapshot.timeline,
      acpTranscript: transcriptResponse,
      codexTranscript: codexTranscriptResponse
    )
    let nextSnapshot = HarnessMonitorSessionWindowSnapshot(
      summary: snapshot.summary,
      detail: detail,
      acpAgents: snapshot.acpAgents,
      acpInspectSample: snapshot.acpInspectSample,
      taskBoardItems: snapshot.taskBoardItems,
      timeline: snapshot.timeline,
      transcript: transcript.entries,
      transcriptSource: transcript.source,
      timelineWindow: snapshot.timelineWindow,
      source: .live
    )
    guard nextSnapshot != snapshot else {
      return nil
    }
    scheduleSessionDetailCacheWrite(
      detail,
      timeline: nextSnapshot.timeline,
      transcript: nextSnapshot.transcript,
      transcriptSource: nextSnapshot.transcriptSource,
      timelineWindow: nextSnapshot.timelineWindow
    )
    return nextSnapshot
  }

  private func loadSessionWindowAcpAgents(
    sessionID: String,
    client: any HarnessMonitorClientProtocol
  ) async -> [AcpAgentSnapshot] {
    do {
      let response = try await client.managedAgents(sessionID: sessionID)
      return response.agents.compactMap(\.acp)
    } catch is CancellationError {
      return []
    } catch {
      return []
    }
  }

  private func loadSessionWindowAcpInspectSample(
    sessionID: String,
    client: any HarnessMonitorClientProtocol
  ) async -> AcpInspectSample? {
    do {
      let response = try await client.acpInspect(sessionID: sessionID)
      return AcpInspectSample(
        sessionID: sessionID,
        sampledAt: response.daemonPerceivedNowDate ?? .now,
        receivedAt: .now,
        agents: response.agents
      )
    } catch is CancellationError {
      return nil
    } catch {
      return nil
    }
  }

  nonisolated static func resolvedSessionWindowTranscript(
    detail: SessionDetail,
    timeline: [TimelineEntry],
    acpTranscript: AcpTranscriptResponse?,
    codexTranscript: CodexTranscriptResponse?
  ) -> (entries: [TimelineEntry], source: HarnessMonitorSessionWindowTranscriptSource) {
    let responseEntries = ((acpTranscript?.entries ?? []) + (codexTranscript?.entries ?? []))
      .filter(\.isManagedRuntimeTranscriptResponseEntry)
    if !responseEntries.isEmpty {
      return (
        normalizedSessionWindowTranscriptEntries(responseEntries, agents: detail.agents),
        .direct
      )
    }
    return (derivedSessionWindowTranscriptEntries(detail: detail, timeline: timeline), .derived)
  }

  nonisolated static func derivedSessionWindowTranscriptEntries(
    detail: SessionDetail,
    timeline: [TimelineEntry]
  ) -> [TimelineEntry] {
    let sessionAgentIDs = Set(detail.agents.map(\.agentId))
    let derivedEntries = timeline.filter {
      $0.matchesDerivedAcpTranscriptHistory(sessionAgentIDs: sessionAgentIDs)
    }
    return normalizedSessionWindowTranscriptEntries(derivedEntries, agents: detail.agents)
  }

  nonisolated static func normalizedSessionWindowTranscriptEntries(
    _ entries: [TimelineEntry],
    agents: [AgentRegistration]
  ) -> [TimelineEntry] {
    typealias ManagedIdentity = (String, (sessionAgentID: String, displayName: String))
    let identitiesByManagedAgentID = Dictionary(
      uniqueKeysWithValues: agents.compactMap { agent -> ManagedIdentity? in
        guard let managedAgentID = agent.managedAgentID else {
          return nil
        }
        return (
          managedAgentID,
          (sessionAgentID: agent.agentId, displayName: agent.name)
        )
      }
    )
    let updatedEntries = entries.map { entry in
      guard
        let identity = sessionWindowTranscriptIdentity(
          for: entry,
          identitiesByManagedAgentID: identitiesByManagedAgentID
        )
      else {
        return entry
      }
      let acpMetadata = entry.acpTimelineIdentityMetadata()
      let codexMetadata = entry.codexTimelineIdentityMetadata()
      let identityChanged =
        entry.agentId != identity.sessionAgentID
        || acpMetadata?.agentID != identity.sessionAgentID
        || acpMetadata?.agentDisplayName != identity.displayName
        || (codexMetadata != nil && codexMetadata?.agentID != identity.sessionAgentID)
        || (codexMetadata != nil && codexMetadata?.agentDisplayName != identity.displayName)
      guard identityChanged else {
        return entry
      }
      return entry.reattributedAcpTimelineEntry(
        sessionAgentID: identity.sessionAgentID,
        displayName: identity.displayName
      )
    }
    return mergedTimelineEntries([], with: updatedEntries)
  }

  nonisolated static func sessionWindowTranscriptIdentity(
    for entry: TimelineEntry,
    identitiesByManagedAgentID: [String: (sessionAgentID: String, displayName: String)]
  ) -> (sessionAgentID: String, displayName: String)? {
    if let metadata = entry.acpTimelineIdentityMetadata(),
      let identity = identitiesByManagedAgentID[metadata.acpAgentID]
    {
      return identity
    }
    if let metadata = entry.codexTimelineIdentityMetadata(),
      let identity = identitiesByManagedAgentID[metadata.runID]
    {
      return identity
    }
    if let agentID = entry.agentId,
      let identity = identitiesByManagedAgentID[agentID]
    {
      return identity
    }
    return nil
  }
}

actor SessionWindowPresentationWorker {
  func resolveTranscript(
    detail: SessionDetail,
    timeline: [TimelineEntry],
    acpTranscript: AcpTranscriptResponse?,
    codexTranscript: CodexTranscriptResponse?
  ) -> (entries: [TimelineEntry], source: HarnessMonitorSessionWindowTranscriptSource) {
    HarnessMonitorStore.resolvedSessionWindowTranscript(
      detail: detail,
      timeline: timeline,
      acpTranscript: acpTranscript,
      codexTranscript: codexTranscript
    )
  }

  func derivedTranscriptEntries(
    detail: SessionDetail,
    timeline: [TimelineEntry]
  ) -> [TimelineEntry] {
    HarnessMonitorStore.derivedSessionWindowTranscriptEntries(
      detail: detail,
      timeline: timeline
    )
  }

  func waitForIdle() {}
}
