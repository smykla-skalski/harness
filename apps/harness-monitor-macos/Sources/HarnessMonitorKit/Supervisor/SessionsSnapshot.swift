import CryptoKit
import Foundation

/// Immutable snapshot handed to each Monitor supervisor tick. The public field list is part of
/// the Phase 1 signature freeze. Phase 2 Unit 1 replaces the `build(from:now:)` body with a real
/// traversal + canonical hash. Rule implementations read the snapshot; they never reach into
/// `HarnessMonitorStore` directly.
public struct SessionsSnapshot: Sendable, Hashable {
  public let id: String
  public let createdAt: Date
  public let hash: String
  public let sessions: [SessionSnapshot]
  public let connection: ConnectionSnapshot

  public init(
    id: String,
    createdAt: Date,
    hash: String,
    sessions: [SessionSnapshot],
    connection: ConnectionSnapshot
  ) {
    self.id = id
    self.createdAt = createdAt
    self.hash = hash
    self.sessions = sessions
    self.connection = connection
  }

  /// An empty snapshot used by Phase 1 stubs and by Phase 2 rule tests that need a zero-state
  /// starting point. The `hash` is the empty string so idempotency keys that embed the snapshot
  /// id are deterministic across tests.
  public static let empty = Self(
    id: "",
    createdAt: Date(timeIntervalSince1970: 0),
    hash: "",
    sessions: [],
    connection: ConnectionSnapshot(kind: "disconnected", lastMessageAt: nil, reconnectAttempt: 0)
  )

  /// Walks the current `HarnessMonitorStore` state, builds a canonical `SessionsSnapshot`, and
  /// stamps it with a SHA-256 hash that deliberately excludes `id` and `createdAt` so two ticks
  /// produced from the same store state hash-compare equal.
  @MainActor
  public static func build(
    from store: HarnessMonitorStore,
    now: Date
  ) async -> Self {
    let sessions = await buildSessions(store: store, now: now)
    let connection = ConnectionSnapshot.from(
      store.connectionState,
      metrics: store.connectionMetrics,
      transport: store.activeTransport
    )
    let hash = await computeCanonicalHashOffMain(
      sessions: sessions,
      connection: connection
    )
    return Self(
      id: UUID().uuidString,
      createdAt: now,
      hash: hash,
      sessions: sessions,
      connection: connection
    )
  }

  nonisolated private static func computeCanonicalHashOffMain(
    sessions: [SessionSnapshot],
    connection: ConnectionSnapshot
  ) async -> String {
    await Task.detached(priority: .userInitiated) {
      canonicalHashSync(sessions: sessions, connection: connection)
    }.value
  }

  @MainActor
  private static func buildSessions(
    store: HarnessMonitorStore,
    now: Date
  ) async -> [SessionSnapshot] {
    let (
      summaries,
      selectedSessionID,
      selectedCodexRuns,
      codexRunsBySessionID,
      cacheService,
      openSessionWindowIDs
    ) =
      await MainActor.run {
        (
          store.sessionIndex.sessions,
          store.selectedSessionID,
          store.selectedCodexRuns,
          store.codexRunsBySessionID,
          store.cacheService,
          store.openSessionWindowIDsSnapshot
        )
      }
    let cachedByID: [String: SessionCacheService.CachedSessionSnapshot] =
      if let cacheService {
        await cacheService.loadSessionDetails(sessionIDs: summaries.map(\.sessionId))
      } else {
        [:]
      }

    return summaries.map { summary -> SessionSnapshot in
      guard let cached = cachedByID[summary.sessionId] else {
        logMissingCache(sessionID: summary.sessionId, openSessionWindowIDs: openSessionWindowIDs)
        return SessionSnapshot.summaryOnly(summary: summary)
      }
      let sessionRuns =
        codexRunsBySessionID[summary.sessionId]
        ?? (selectedSessionID == summary.sessionId ? selectedCodexRuns : [])
      return SessionSnapshot.from(
        detail: cached.detail,
        summary: summary,
        timeline: cached.timeline,
        pendingCodexRuns: sessionRuns,
        now: now
      )
    }
  }

  private static func logMissingCache(
    sessionID: String,
    openSessionWindowIDs: Set<String>
  ) {
    if openSessionWindowIDs.contains(sessionID) {
      HarnessMonitorLogger.supervisorWarning(
        "supervisor.snapshot missing_cache_for_open_window session=\(sessionID)"
      )
    } else {
      HarnessMonitorLogger.supervisorDebug(
        "supervisor.snapshot summary_only session=\(sessionID)"
      )
    }
  }

  nonisolated private static func canonicalHashSync(
    sessions: [SessionSnapshot],
    connection: ConnectionSnapshot
  ) -> String {
    let payload = SessionsCanonicalPayload(
      sessions: sessions.map(SessionCanonicalPayload.init(session:)),
      connection: connection
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(payload) else {
      return ""
    }
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}

public struct SessionSnapshot: Sendable, Hashable, Codable {
  public let id: String
  public let title: String?
  public let statusRaw: String
  public let agents: [AgentSnapshot]
  public let tasks: [TaskSnapshot]
  public let timelineDensityLastMinute: Int
  public let observerIssues: [ObserverIssueSnapshot]
  public let pendingCodexApprovals: [CodexApprovalSnapshot]

  public init(
    id: String,
    title: String?,
    statusRaw: String = "active",
    agents: [AgentSnapshot],
    tasks: [TaskSnapshot],
    timelineDensityLastMinute: Int,
    observerIssues: [ObserverIssueSnapshot],
    pendingCodexApprovals: [CodexApprovalSnapshot]
  ) {
    self.id = id
    self.title = title
    self.statusRaw = statusRaw
    self.agents = agents
    self.tasks = tasks
    self.timelineDensityLastMinute = timelineDensityLastMinute
    self.observerIssues = observerIssues
    self.pendingCodexApprovals = pendingCodexApprovals
  }

  @MainActor
  fileprivate static func from(
    detail: SessionDetail,
    summary: SessionSummary,
    timeline: [TimelineEntry],
    pendingCodexRuns: [CodexRunSnapshot],
    now: Date
  ) -> Self {
    let agents = detail.agents.map { AgentSnapshot.from(registration: $0, now: now) }
    let tasks = detail.tasks.map(TaskSnapshot.from(workItem:))
    let observerLastScanTime =
      detail.observer.flatMap { SessionsSnapshotDateParser.parse($0.lastScanTime) }
    let observerIssues =
      detail.observer?.openIssues?.map {
        ObserverIssueSnapshot.from(summary: $0, firstSeen: observerLastScanTime)
      } ?? []
    let timelineDensityLastMinute = timeline.reduce(into: 0) { count, entry in
      guard let timestamp = SessionsSnapshotDateParser.parse(entry.recordedAt) else { return }
      guard timestamp <= now, now.timeIntervalSince(timestamp) < 60 else { return }
      count += 1
    }
    return Self(
      id: summary.sessionId,
      title: summary.title,
      statusRaw: summary.status.rawValue,
      agents: agents,
      tasks: tasks,
      timelineDensityLastMinute: timelineDensityLastMinute,
      observerIssues: observerIssues,
      pendingCodexApprovals: CodexApprovalSnapshot.from(runs: pendingCodexRuns)
    )
  }
}

public struct AgentSnapshot: Sendable, Hashable, Codable {
  public let id: String
  public let runtime: String
  public let statusRaw: String
  public let lastActivityAt: Date?
  public let idleSeconds: Int?
  public let currentTaskID: String?

  public init(
    id: String,
    runtime: String,
    statusRaw: String,
    lastActivityAt: Date?,
    idleSeconds: Int?,
    currentTaskID: String?
  ) {
    self.id = id
    self.runtime = runtime
    self.statusRaw = statusRaw
    self.lastActivityAt = lastActivityAt
    self.idleSeconds = idleSeconds
    self.currentTaskID = currentTaskID
  }

  @MainActor
  fileprivate static func from(registration: AgentRegistration, now: Date) -> Self {
    let lastActivityAt = registration.lastActivityAt.flatMap(SessionsSnapshotDateParser.parse)
    let idleSeconds = lastActivityAt.map { max(0, Int(now.timeIntervalSince($0).rounded())) }
    return Self(
      id: registration.agentId,
      runtime: registration.runtime,
      statusRaw: registration.status.rawValue,
      lastActivityAt: lastActivityAt,
      idleSeconds: idleSeconds,
      currentTaskID: registration.currentTaskId
    )
  }
}

public struct TaskSnapshot: Sendable, Hashable, Codable {
  public let id: String
  public let statusRaw: String
  public let assignedAgentID: String?
  public let createdAt: Date
  public let severityRaw: String

  public init(
    id: String,
    statusRaw: String,
    assignedAgentID: String?,
    createdAt: Date,
    severityRaw: String
  ) {
    self.id = id
    self.statusRaw = statusRaw
    self.assignedAgentID = assignedAgentID
    self.createdAt = createdAt
    self.severityRaw = severityRaw
  }

  @MainActor
  fileprivate static func from(workItem: WorkItem) -> Self {
    let createdAt =
      SessionsSnapshotDateParser.parse(workItem.createdAt) ?? Date(timeIntervalSince1970: 0)
    return Self(
      id: workItem.taskId,
      statusRaw: workItem.status.rawValue,
      assignedAgentID: workItem.assignedTo,
      createdAt: createdAt,
      severityRaw: workItem.severity.rawValue
    )
  }
}

public struct ObserverIssueSnapshot: Sendable, Hashable, Codable {
  public let id: String
  public let severityRaw: String
  public let code: String
  public let firstSeen: Date?
  public let count: Int

  public init(
    id: String,
    severityRaw: String,
    code: String,
    firstSeen: Date?,
    count: Int
  ) {
    self.id = id
    self.severityRaw = severityRaw
    self.code = code
    self.firstSeen = firstSeen
    self.count = count
  }

  fileprivate static func from(summary: ObserverIssueSummary, firstSeen: Date?) -> Self {
    Self(
      id: summary.issueId,
      severityRaw: summary.severity,
      code: summary.code,
      firstSeen: firstSeen,
      count: summary.occurrenceCount ?? 0
    )
  }
}

public struct CodexApprovalSnapshot: Sendable, Hashable, Codable {
  public let id: String
  public let agentID: String
  public let title: String
  public let detail: String
  public let receivedAt: Date

  public init(
    id: String,
    agentID: String,
    title: String,
    detail: String,
    receivedAt: Date
  ) {
    self.id = id
    self.agentID = agentID
    self.title = title
    self.detail = detail
    self.receivedAt = receivedAt
  }
}

public struct ConnectionSnapshot: Sendable, Hashable, Codable {
  public let kind: String
  public let lastMessageAt: Date?
  public let disconnectedSince: Date?
  public let reconnectAttempt: Int

  public init(
    kind: String,
    lastMessageAt: Date?,
    disconnectedSince: Date? = nil,
    reconnectAttempt: Int
  ) {
    self.kind = kind
    self.lastMessageAt = lastMessageAt
    self.disconnectedSince = disconnectedSince
    self.reconnectAttempt = reconnectAttempt
  }

  fileprivate static func from(
    _ state: HarnessMonitorStore.ConnectionState,
    metrics: ConnectionMetrics,
    transport: TransportKind
  ) -> Self {
    let kind: String
    switch state {
    case .idle:
      kind = "idle"
    case .connecting, .offline:
      kind = "disconnected"
    case .online:
      switch transport {
      case .webSocket:
        kind = "ws"
      case .httpSSE:
        kind = "sse"
      }
    }
    return Self(
      kind: kind,
      lastMessageAt: metrics.lastMessageAt,
      disconnectedSince: kind == "disconnected" ? metrics.disconnectedSince : nil,
      reconnectAttempt: metrics.reconnectAttempt
    )
  }
}
