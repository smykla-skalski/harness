import Foundation
import HarnessMonitorCore

struct MobileRemoteManagedAgentsSnapshot: Sendable {
  var agentsBySessionID: [String: [MobileAgentSummary]]
  var attention: [MobileAttentionItem]
}

struct MobileRemoteManagedAgentsSession: Sendable {
  var id: String
  var title: String
}

private struct MobileRemoteManagedAgentsFetchResult: Sendable {
  var sessionID: String
  var agents: [MobileRemoteManagedAgentWire]
}

extension MobileRemoteDaemonSyncClient {
  func fetchManagedAgentsSnapshot(
    for sessions: [MobileRemoteManagedAgentsSession],
    now: Date
  ) async throws -> MobileRemoteManagedAgentsSnapshot {
    let wiresBySessionID = try await fetchManagedAgentWires(for: sessions)
    let redactor = MobileMirrorSecretRedactor()
    var agentsBySessionID: [String: [MobileAgentSummary]] = [:]
    var attention: [MobileAttentionItem] = []
    for session in sessions {
      let wires = wiresBySessionID[session.id] ?? []
      let agents = wires.map {
        $0.mobileSummary(stationID: stationID, now: now, redactor: redactor)
      }
      .sorted(by: Self.sortManagedAgents)
      agentsBySessionID[session.id] = agents
      attention.append(
        contentsOf: managedAgentAttention(
          wires: wires,
          agents: agents,
          session: session,
          now: now,
          redactor: redactor
        )
      )
    }
    return MobileRemoteManagedAgentsSnapshot(
      agentsBySessionID: agentsBySessionID,
      attention: attention
    )
  }

  private func fetchManagedAgentWires(
    for sessions: [MobileRemoteManagedAgentsSession]
  ) async throws -> [String: [MobileRemoteManagedAgentWire]] {
    let batchSize = 6
    var agentsBySessionID: [String: [MobileRemoteManagedAgentWire]] = [:]
    for startIndex in stride(from: 0, to: sessions.count, by: batchSize) {
      let endIndex = min(startIndex + batchSize, sessions.count)
      let batch = sessions[startIndex..<endIndex]
      try await withThrowingTaskGroup(of: MobileRemoteManagedAgentsFetchResult.self) { group in
        for session in batch {
          group.addTask {
            MobileRemoteManagedAgentsFetchResult(
              sessionID: session.id,
              agents: try await fetchManagedAgents(sessionID: session.id)
            )
          }
        }
        for try await result in group {
          agentsBySessionID[result.sessionID] = result.agents
        }
      }
    }
    return agentsBySessionID
  }

  private func fetchManagedAgents(
    sessionID: String
  ) async throws -> [MobileRemoteManagedAgentWire] {
    let path = "/v1/sessions/\(try sessionID.remotePathComponent())/managed-agents"
    var request = try authenticatedRequest(path: path, method: "GET")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw MobileRemoteDaemonSyncError.invalidResponse
    }
    guard response.statusCode != 404 else {
      return []
    }
    try validate(response)
    return try JSONDecoder().decode(MobileRemoteManagedAgentListWire.self, from: data).agents
  }

  private func managedAgentAttention(
    wires: [MobileRemoteManagedAgentWire],
    agents: [MobileAgentSummary],
    session: MobileRemoteManagedAgentsSession,
    now: Date,
    redactor: MobileMirrorSecretRedactor
  ) -> [MobileAttentionItem] {
    var agentsByID: [String: MobileAgentSummary] = [:]
    for agent in agents {
      agentsByID[agent.id] = agent
    }
    return wires.flatMap { wire -> [MobileAttentionItem] in
      guard let agent = agentsByID[wire.managedAgentID] else {
        return []
      }
      let permissions = wire.permissionBatches
      if !permissions.isEmpty {
        return permissions.map {
          permissionAttention(
            batch: $0,
            agent: agent,
            session: session,
            now: now,
            redactor: redactor
          )
        }
      }
      return agent.isBlocked
        ? [blockedAgentAttention(agent: agent, session: session, redactor: redactor)]
        : []
    }
  }

  private func permissionAttention(
    batch: MobileRemoteAcpPermissionBatchWire,
    agent: MobileAgentSummary,
    session: MobileRemoteManagedAgentsSession,
    now: Date,
    redactor: MobileMirrorSecretRedactor
  ) -> MobileAttentionItem {
    let exposesCommand = access.canWrite
    let requestLabel = batch.requestCount == 1 ? "request" : "requests"
    return MobileAttentionItem(
      id: "acp-\(batch.batchID)",
      stationID: stationID,
      kind: .acpDecision,
      severity: .critical,
      title: redactor.redact("Permission requested by \(agent.displayName)"),
      subtitle: redactor.redact(
        "\(batch.requestCount) \(requestLabel) waiting in \(session.title)."
      ),
      updatedAt: MobileRemoteSessionDate.parse(batch.createdAt) ?? now,
      commandKind: exposesCommand ? .acpPermissionDecision : nil,
      target: MobileCommandTarget(
        stationID: stationID,
        sessionID: batch.sessionID,
        agentID: batch.managedAgentID,
        targetRevision: 0
      ),
      commandPayload: exposesCommand
        ? ["batchID": batch.batchID, "decision": "approve_all"]
        : [:]
    )
  }

  private func blockedAgentAttention(
    agent: MobileAgentSummary,
    session: MobileRemoteManagedAgentsSession,
    redactor: MobileMirrorSecretRedactor
  ) -> MobileAttentionItem {
    let exposesCommand = access.canWrite && agent.isActive
    return MobileAttentionItem(
      id: "blocked-\(agent.id)",
      stationID: stationID,
      kind: .blockedAgent,
      severity: .warning,
      title: redactor.redact("\(agent.displayName) is waiting"),
      subtitle: redactor.redact(session.title),
      updatedAt: agent.lastActivityAt,
      commandKind: exposesCommand ? .agentPrompt : nil,
      target: MobileCommandTarget(
        stationID: stationID,
        sessionID: agent.sessionID,
        agentID: agent.id,
        targetRevision: 0
      ),
      commandPayload: exposesCommand
        ? ["prompt": "Please summarize what you need from me."]
        : [:]
    )
  }

  private static func sortManagedAgents(
    _ lhs: MobileAgentSummary,
    _ rhs: MobileAgentSummary
  ) -> Bool {
    if lhs.isBlocked != rhs.isBlocked {
      return lhs.isBlocked && !rhs.isBlocked
    }
    if lhs.isActive != rhs.isActive {
      return lhs.isActive && !rhs.isActive
    }
    if lhs.lastActivityAt != rhs.lastActivityAt {
      return lhs.lastActivityAt > rhs.lastActivityAt
    }
    return lhs.id < rhs.id
  }
}
