import Foundation
import HarnessMonitorCore
import HarnessMonitorKit

public protocol MobileMirrorClient: Sendable {
  func health() async throws -> HealthResponse
  func sessions() async throws -> [SessionSummary]
  func sessionDetail(id: String, scope: String?) async throws -> SessionDetail
  func managedAgents(sessionID: String) async throws -> ManagedAgentListResponse
  func queryReviews(request: ReviewsQueryRequest) async throws -> ReviewsQueryResponse
  func taskBoardItems(status: TaskBoardStatus?) async throws -> [TaskBoardItem]
}

public struct HarnessMonitorClientMobileMirrorClient: MobileMirrorClient {
  private let client: any HarnessMonitorClientProtocol

  public init(client: any HarnessMonitorClientProtocol) {
    self.client = client
  }

  public func health() async throws -> HealthResponse {
    try await client.health()
  }

  public func sessions() async throws -> [SessionSummary] {
    try await client.sessions()
  }

  public func sessionDetail(id: String, scope: String?) async throws -> SessionDetail {
    try await client.sessionDetail(id: id, scope: scope)
  }

  public func managedAgents(sessionID: String) async throws -> ManagedAgentListResponse {
    try await client.managedAgents(sessionID: sessionID)
  }

  public func queryReviews(request: ReviewsQueryRequest) async throws -> ReviewsQueryResponse {
    try await client.queryReviews(request: request)
  }

  public func taskBoardItems(status: TaskBoardStatus?) async throws -> [TaskBoardItem] {
    try await client.taskBoardItems(status: status)
  }
}

public actor HarnessMonitorClientMobileMirrorSnapshotSource: MobileMirrorSnapshotSource {
  private let stationID: String
  private let stationName: String
  private let clientProvider: @Sendable () async -> (any MobileMirrorClient)?
  private let reviewsQueryProvider: @Sendable () async -> ReviewsQueryRequest?
  private let trustedDeviceProvider: @Sendable () async throws -> [MobileDeviceDescriptor]
  private let retention: TimeInterval
  private var revision: Int64
  private var lastSnapshot: MobileMirrorSnapshot?

  public init(
    stationID: String,
    stationName: String,
    clientProvider: @escaping @Sendable () async -> (any MobileMirrorClient)?,
    reviewsQueryProvider: @escaping @Sendable () async -> ReviewsQueryRequest? = { nil },
    trustedDeviceProvider: @escaping @Sendable () async throws -> [MobileDeviceDescriptor] = {
      []
    },
    initialRevision: Int64 = 0,
    retention: TimeInterval = 7 * 24 * 60 * 60
  ) {
    self.stationID = stationID
    self.stationName = stationName
    self.clientProvider = clientProvider
    self.reviewsQueryProvider = reviewsQueryProvider
    self.trustedDeviceProvider = trustedDeviceProvider
    self.revision = initialRevision
    self.retention = retention
  }

  public func makeSnapshot(now: Date) async throws -> MobileMirrorSnapshot {
    let nextRevision = incrementRevision()
    guard let client = await clientProvider() else {
      return try await unavailableSnapshot(
        now: now,
        revision: nextRevision,
        message: "Mac relay is waiting for the Harness daemon connection."
      )
    }

    do {
      let health = try await client.health()
      let sessions = try await client.sessions()
      let detailsBySessionID = await fetchSessionDetails(
        client: client,
        sessions: sessions
      )
      let agentsBySessionID = await fetchManagedAgents(
        client: client,
        sessions: sessions
      )
      let reviewFetch = await fetchReviews(client: client, now: now)
      let taskBoardFetch = await fetchTaskBoard(client: client, now: now)
      let trustedDevices = try await trustedDeviceProvider()
      let snapshot = makeSnapshot(
        now: now,
        revision: nextRevision,
        health: health,
        sessions: sessions,
        detailsBySessionID: detailsBySessionID,
        agentsBySessionID: agentsBySessionID,
        reviews: reviewFetch.reviews,
        reviewIssueAttention: reviewFetch.attention,
        taskBoardItems: taskBoardFetch.items,
        taskBoardIssueAttention: taskBoardFetch.attention,
        trustedDevices: trustedDevices
      )
      lastSnapshot = snapshot
      return snapshot
    } catch {
      return try await unavailableSnapshot(
        now: now,
        revision: nextRevision,
        message: "Mac relay could not refresh Monitor state: \(String(describing: error))"
      )
    }
  }

  private func incrementRevision() -> Int64 {
    revision += 1
    return revision
  }

  private func makeSnapshot(
    now: Date,
    revision: Int64,
    health: HealthResponse,
    sessions: [SessionSummary],
    detailsBySessionID: [String: SessionDetail],
    agentsBySessionID: [String: [ManagedAgentSnapshot]],
    reviews: [ReviewItem],
    reviewIssueAttention: MobileAttentionItem?,
    taskBoardItems: [TaskBoardItem],
    taskBoardIssueAttention: MobileAttentionItem?,
    trustedDevices: [MobileDeviceDescriptor]
  ) -> MobileMirrorSnapshot {
    var attention: [MobileAttentionItem] = []
    attention.append(
      contentsOf: acpPermissionAttention(
        sessions: sessions,
        agentsBySessionID: agentsBySessionID,
        revision: revision,
        now: now
      ))
    attention.append(
      contentsOf: reviewAttention(
        reviews: reviews,
        revision: revision,
        now: now
      ))
    if let reviewIssueAttention {
      attention.append(reviewIssueAttention)
    }
    attention.append(
      contentsOf: sessionTaskAttention(
        sessions: sessions,
        detailsBySessionID: detailsBySessionID,
        revision: revision,
        now: now
      ))
    attention.append(
      contentsOf: taskBoardAttention(
        items: taskBoardItems,
        revision: revision,
        now: now
      ))
    if let taskBoardIssueAttention {
      attention.append(taskBoardIssueAttention)
    }
    attention.append(
      contentsOf: blockedAgentAttention(
        sessions: sessions,
        agentsBySessionID: agentsBySessionID,
        revision: revision,
        now: now
      ))

    let mobileSessions = sessions.map { session in
      let agents = agentsBySessionID[session.sessionId] ?? []
      return mobileSession(
        session,
        agents: agents,
        now: now
      )
    }
    let mobileReviews = reviews.map { mobileReview($0, now: now) }
    let needsYouCount = attention.count { $0.needsUserAction }
    let station = MobileStationSummary(
      id: stationID,
      displayName: stationName,
      state: health.status.lowercased() == "ok" ? .online : .stale,
      lastSeenAt: now,
      activeSessionCount: sessions.filter { $0.status != .ended }.count,
      needsYouCount: needsYouCount,
      commandQueueCount: lastSnapshot?.station(id: stationID)?.commandQueueCount ?? 0,
      defaultStation: true
    )

    return MobileMirrorSnapshot(
      revision: revision,
      generatedAt: now,
      expiresAt: now.addingTimeInterval(retention),
      stations: [station],
      attention: attention,
      sessions: mobileSessions,
      reviews: mobileReviews,
      commands: lastSnapshot?.commands ?? [],
      trustedDevices: trustedDevices
    )
  }

  private func unavailableSnapshot(
    now: Date,
    revision: Int64,
    message: String
  ) async throws -> MobileMirrorSnapshot {
    let trustedDevices = try await trustedDeviceProvider()
    let previousStation = lastSnapshot?.station(id: stationID)
    let activeSessionCount = previousStation?.activeSessionCount ?? 0
    let previousCommandQueueCount = previousStation?.commandQueueCount ?? 0
    let attention = [
      MobileAttentionItem(
        id: "station-health-\(stationID)",
        stationID: stationID,
        kind: .stationHealth,
        severity: .warning,
        title: "Mac relay is stale",
        subtitle: message,
        updatedAt: now
      )
    ]
    let station = MobileStationSummary(
      id: stationID,
      displayName: stationName,
      state: .stale,
      lastSeenAt: previousStation?.lastSeenAt ?? now,
      activeSessionCount: activeSessionCount,
      needsYouCount: attention.count,
      commandQueueCount: previousCommandQueueCount,
      defaultStation: true
    )

    let snapshot = MobileMirrorSnapshot(
      revision: revision,
      generatedAt: now,
      expiresAt: now.addingTimeInterval(retention),
      stations: [station],
      attention: attention,
      sessions: lastSnapshot?.sessions ?? [],
      reviews: lastSnapshot?.reviews ?? [],
      commands: lastSnapshot?.commands ?? [],
      trustedDevices: trustedDevices
    )
    lastSnapshot = snapshot
    return snapshot
  }

  private func fetchSessionDetails(
    client: any MobileMirrorClient,
    sessions: [SessionSummary]
  ) async -> [String: SessionDetail] {
    var detailsBySessionID: [String: SessionDetail] = [:]
    for session in sessions where session.status != .ended {
      do {
        detailsBySessionID[session.sessionId] = try await client.sessionDetail(
          id: session.sessionId,
          scope: "core"
        )
      } catch {
        continue
      }
    }
    return detailsBySessionID
  }

  private func fetchManagedAgents(
    client: any MobileMirrorClient,
    sessions: [SessionSummary]
  ) async -> [String: [ManagedAgentSnapshot]] {
    var agentsBySessionID: [String: [ManagedAgentSnapshot]] = [:]
    for session in sessions where session.status != .ended {
      do {
        agentsBySessionID[session.sessionId] =
          try await client.managedAgents(sessionID: session.sessionId).agents
      } catch {
        agentsBySessionID[session.sessionId] = []
      }
    }
    return agentsBySessionID
  }

  private func fetchReviews(
    client: any MobileMirrorClient,
    now: Date
  ) async -> MobileRelayReviewFetchResult {
    guard let request = await reviewsQueryProvider() else {
      return MobileRelayReviewFetchResult(
        reviews: [],
        attention: reviewsUnavailableAttention(
          title: "Reviews are not configured",
          subtitle: "Configure Review repositories on the Mac to mirror pull requests.",
          severity: .info,
          now: now
        )
      )
    }
    do {
      let response = try await client.queryReviews(
        request: request
      )
      return MobileRelayReviewFetchResult(reviews: response.items)
    } catch {
      return MobileRelayReviewFetchResult(
        reviews: [],
        attention: reviewsUnavailableAttention(
          title: "Reviews mirror failed",
          subtitle: "The Mac could not refresh Reviews. Check Review settings and GitHub access.",
          severity: .warning,
          now: now
        )
      )
    }
  }

  private func fetchTaskBoard(
    client: any MobileMirrorClient,
    now: Date
  ) async -> MobileRelayTaskBoardFetchResult {
    do {
      let items = try await client.taskBoardItems(status: nil)
        .filter { $0.deletedAt == nil }
      return MobileRelayTaskBoardFetchResult(items: items)
    } catch {
      return MobileRelayTaskBoardFetchResult(
        items: [],
        attention: MobileAttentionItem(
          id: "task-board-unavailable-\(stationID)",
          stationID: stationID,
          kind: .stationHealth,
          severity: .warning,
          title: "Task board mirror failed",
          subtitle: "The Mac could not refresh task-board items for mobile.",
          updatedAt: now,
          commandKind: .refresh,
          target: MobileCommandTarget(
            stationID: stationID,
            targetRevision: revision
          ),
          commandPayload: ["scope": "taskBoard"]
        )
      )
    }
  }

  private func reviewsUnavailableAttention(
    title: String,
    subtitle: String,
    severity: MobileAttentionSeverity,
    now: Date
  ) -> MobileAttentionItem {
    MobileAttentionItem(
      id: "reviews-unavailable-\(stationID)",
      stationID: stationID,
      kind: .stationHealth,
      severity: severity,
      title: title,
      subtitle: subtitle,
      updatedAt: now,
      commandKind: .refresh,
      target: MobileCommandTarget(
        stationID: stationID,
        targetRevision: revision
      ),
      commandPayload: ["scope": "reviews"]
    )
  }

  private func acpPermissionAttention(
    sessions: [SessionSummary],
    agentsBySessionID: [String: [ManagedAgentSnapshot]],
    revision: Int64,
    now: Date
  ) -> [MobileAttentionItem] {
    let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionId, $0) })
    return agentsBySessionID.values.flatMap { agents in
      agents.flatMap { agent -> [MobileAttentionItem] in
        guard case .acp(let acp) = agent else {
          return []
        }
        return acp.pendingPermissionBatches.map { batch in
          let requestCount = batch.requests.count
          let session = sessionsByID[batch.sessionId]
          return MobileAttentionItem(
            id: "acp-\(batch.batchId)",
            stationID: stationID,
            kind: .acpDecision,
            severity: .critical,
            title: "Permission requested by \(acp.displayName)",
            subtitle:
              "\(requestCount) request\(requestCount == 1 ? "" : "s") waiting in \(session?.displayTitle ?? batch.sessionId).",
            updatedAt: parseDate(batch.createdAt, fallback: now),
            commandKind: .acpPermissionDecision,
            target: MobileCommandTarget(
              stationID: stationID,
              sessionID: batch.sessionId,
              agentID: batch.acpId,
              targetRevision: revision
            ),
            commandPayload: ["batchID": batch.batchId, "decision": "approve_all"]
          )
        }
      }
    }
  }

  private func reviewAttention(
    reviews: [ReviewItem],
    revision: Int64,
    now: Date
  ) -> [MobileAttentionItem] {
    reviews.filter(needsReviewAttention).map { review in
      MobileAttentionItem(
        id: "review-\(review.pullRequestID)",
        stationID: stationID,
        kind: .pullRequest,
        severity: review.policyBlocked || review.checkStatus == .failure ? .critical : .warning,
        title: "\(review.repository) #\(review.number) needs you",
        subtitle: review.title,
        updatedAt: parseDate(review.updatedAt, fallback: now),
        commandKind: review.checkStatus == .failure ? .pullRequestRerunChecks : .pullRequestApprove,
        target: MobileCommandTarget(
          stationID: stationID,
          reviewID: review.pullRequestID,
          targetRevision: revision
        ),
        commandPayload: reviewPayload(review)
      )
    }
  }

  private func taskBoardAttention(
    items: [TaskBoardItem],
    revision: Int64,
    now: Date
  ) -> [MobileAttentionItem] {
    items.compactMap { item in
      switch item.status {
      case .planReview:
        return MobileAttentionItem(
          id: "task-board-plan-\(item.id)",
          stationID: stationID,
          kind: .taskBoard,
          severity: .critical,
          title: "Plan approval needed",
          subtitle: taskBoardSubtitle(item),
          updatedAt: parseDate(item.updatedAt, fallback: now),
          commandKind: .taskBoardPlanApproval,
          target: MobileCommandTarget(
            stationID: stationID,
            taskID: item.id,
            targetRevision: revision
          ),
          commandPayload: ["approvedBy": "mobile"]
        )
      case .needsYou:
        return MobileAttentionItem(
          id: "task-board-needs-you-\(item.id)",
          stationID: stationID,
          kind: .taskBoard,
          severity: taskBoardSeverity(item),
          title: "Task needs you",
          subtitle: taskBoardSubtitle(item),
          updatedAt: parseDate(item.updatedAt, fallback: now),
          commandKind: .taskBoardDispatch,
          target: MobileCommandTarget(
            stationID: stationID,
            taskID: item.id,
            targetRevision: revision
          ),
          commandPayload: [
            "itemID": item.id,
            "status": "todo",
            "dryRun": "false",
          ]
        )
      case .blocked:
        return MobileAttentionItem(
          id: "task-board-blocked-\(item.id)",
          stationID: stationID,
          kind: .taskBoard,
          severity: taskBoardSeverity(item),
          title: "Task is blocked",
          subtitle: taskBoardSubtitle(item),
          updatedAt: parseDate(item.updatedAt, fallback: now),
          commandKind: .refresh,
          target: MobileCommandTarget(
            stationID: stationID,
            taskID: item.id,
            targetRevision: revision
          ),
          commandPayload: ["scope": "taskBoard"]
        )
      default:
        return nil
      }
    }
  }

  private func sessionTaskAttention(
    sessions: [SessionSummary],
    detailsBySessionID: [String: SessionDetail],
    revision: Int64,
    now: Date
  ) -> [MobileAttentionItem] {
    let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionId, $0) })
    return detailsBySessionID.values.flatMap { detail in
      let session = sessionsByID[detail.session.sessionId] ?? detail.session
      return detail.tasks.compactMap { task in
        sessionTaskAttention(
          session: session,
          task: task,
          revision: revision,
          now: now
        )
      }
    }
  }

  private func sessionTaskAttention(
    session: SessionSummary,
    task: WorkItem,
    revision: Int64,
    now: Date
  ) -> MobileAttentionItem? {
    let title: String
    let severity: MobileAttentionSeverity
    switch task.status {
    case .awaitingReview:
      title = "Task awaiting review"
      severity = sessionTaskSeverity(task)
    case .blocked:
      title = "Task is blocked"
      severity = sessionTaskSeverity(task)
    case .open, .inProgress, .inReview, .done:
      guard task.requiresArbitrationBanner else {
        return nil
      }
      title = "Task arbitration needed"
      severity = .critical
    }

    return MobileAttentionItem(
      id: "session-task-\(session.sessionId)-\(task.taskId)",
      stationID: stationID,
      kind: .taskBoard,
      severity: severity,
      title: title,
      subtitle: sessionTaskSubtitle(session: session, task: task),
      updatedAt: parseDate(task.updatedAt, fallback: now),
      commandKind: .refresh,
      target: MobileCommandTarget(
        stationID: stationID,
        sessionID: session.sessionId,
        taskID: task.taskId,
        targetRevision: revision
      ),
      commandPayload: [
        "scope": "sessionTasks",
        "sessionID": session.sessionId,
        "taskID": task.taskId,
        "status": task.status.rawValue,
      ]
    )
  }

  private func blockedAgentAttention(
    sessions: [SessionSummary],
    agentsBySessionID: [String: [ManagedAgentSnapshot]],
    revision: Int64,
    now: Date
  ) -> [MobileAttentionItem] {
    let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionId, $0) })
    return agentsBySessionID.values.flatMap { agents in
      agents.compactMap { agent -> MobileAttentionItem? in
        guard isBlocked(agent), agent.acp?.pendingPermissionBatches.isEmpty != false else {
          return nil
        }
        let session = sessionsByID[agent.sessionId]
        return MobileAttentionItem(
          id: "blocked-\(agent.managedAgentID)",
          stationID: stationID,
          kind: .blockedAgent,
          severity: .warning,
          title: "\(agent.displayTitle) is waiting",
          subtitle: session?.displayTitle ?? agent.sessionId,
          updatedAt: parseDate(agent.updatedAt, fallback: now),
          commandKind: .agentPrompt,
          target: MobileCommandTarget(
            stationID: stationID,
            sessionID: agent.sessionId,
            agentID: agent.managedAgentID,
            targetRevision: revision
          ),
          commandPayload: ["prompt": "Please summarize what you need from me."]
        )
      }
    }
  }

  private func sessionTaskSeverity(_ task: WorkItem) -> MobileAttentionSeverity {
    switch task.severity {
    case .critical:
      .critical
    case .high, .medium, .low:
      .warning
    }
  }

  private func sessionTaskSubtitle(session: SessionSummary, task: WorkItem) -> String {
    let detail =
      task.blockedReason?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? task.context?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? ""
    let summary = detail.isEmpty ? task.title : detail
    let trimmedSummary =
      summary.count > 140
      ? "\(summary.prefix(137))..."
      : summary
    return "\(session.displayTitle) - \(task.title) - \(task.severity.title). \(trimmedSummary)"
  }

  private func mobileSession(
    _ session: SessionSummary,
    agents: [ManagedAgentSnapshot],
    now: Date
  ) -> MobileSessionSummary {
    MobileSessionSummary(
      id: session.sessionId,
      stationID: stationID,
      projectName: session.projectName,
      title: session.displayTitle,
      branch: session.branchRef,
      status: session.status.title,
      activeAgentCount: agents.count(where: isActive),
      blockedAgentCount: agents.count(where: isBlocked),
      lastActivityAt: parseDate(session.lastActivityAt ?? session.updatedAt, fallback: now),
      summary: session.context,
      agents: agents.map { mobileAgent($0, now: now) }
        .sorted { lhs, rhs in
          if lhs.isBlocked != rhs.isBlocked {
            return lhs.isBlocked && !rhs.isBlocked
          }
          if lhs.isActive != rhs.isActive {
            return lhs.isActive && !rhs.isActive
          }
          return lhs.lastActivityAt > rhs.lastActivityAt
        }
    )
  }

  private func mobileAgent(
    _ agent: ManagedAgentSnapshot,
    now: Date
  ) -> MobileAgentSummary {
    switch agent {
    case .terminal(let snapshot):
      return MobileAgentSummary(
        id: snapshot.managedAgentID,
        stationID: stationID,
        sessionID: snapshot.sessionId,
        displayName: "\(snapshot.runtime) \(snapshot.agentId)",
        family: .terminal,
        status: snapshot.status.title,
        role: nil,
        isActive: snapshot.status.isActive,
        isBlocked: snapshot.status == .failed,
        lastActivityAt: parseDate(snapshot.updatedAt, fallback: now),
        summary: snapshot.error ?? snapshot.projectDir
      )
    case .codex(let snapshot):
      let pendingApprovals = snapshot.pendingApprovals.count
      return MobileAgentSummary(
        id: snapshot.managedAgentID,
        stationID: stationID,
        sessionID: snapshot.sessionId,
        displayName: snapshot.displayName ?? snapshot.runId,
        family: .codex,
        status: snapshot.status.title,
        role: nil,
        isActive: snapshot.status.isActive,
        isBlocked: snapshot.status == .waitingApproval || pendingApprovals > 0
          || snapshot.status == .failed,
        pendingApprovalCount: pendingApprovals,
        lastActivityAt: parseDate(snapshot.updatedAt, fallback: now),
        summary: snapshot.latestSummary ?? snapshot.finalMessage ?? snapshot.error
          ?? snapshot.prompt
      )
    case .acp(let snapshot):
      return MobileAgentSummary(
        id: snapshot.managedAgentID,
        stationID: stationID,
        sessionID: snapshot.sessionId,
        displayName: snapshot.displayName,
        family: .acp,
        status: snapshot.status.title,
        role: nil,
        isActive: snapshot.status == .active,
        isBlocked: snapshot.pendingPermissions > 0 || snapshot.status == .awaitingReview,
        pendingPermissionCount: snapshot.pendingPermissions,
        lastActivityAt: parseDate(snapshot.updatedAt, fallback: now),
        summary: snapshot.stderrTail ?? snapshot.projectDir
      )
    }
  }

  private func mobileReview(_ review: ReviewItem, now: Date) -> MobileReviewSummary {
    MobileReviewSummary(
      id: review.pullRequestID,
      stationID: stationID,
      repositoryID: review.repositoryID,
      repository: review.repository,
      number: Int(review.number),
      url: review.url,
      title: review.title,
      author: review.authorLogin,
      state: review.state.rawValue,
      checksSummary: review.checkStatus.rawValue,
      headSha: review.headSha,
      mergeable: review.mergeable.rawValue,
      reviewStatus: review.reviewStatus.rawValue,
      checkStatus: review.checkStatus.rawValue,
      policyBlocked: review.policyBlocked,
      isDraft: review.isDraft,
      needsYou: needsReviewAttention(review),
      updatedAt: parseDate(review.updatedAt, fallback: now)
    )
  }

  private func needsReviewAttention(_ review: ReviewItem) -> Bool {
    review.reviewStatus == .reviewRequired
      || review.policyBlocked
      || review.checkStatus == .failure
  }

  private func reviewPayload(_ review: ReviewItem) -> [String: String] {
    [
      "repository": review.repository,
      "number": String(review.number),
      "headSha": review.headSha,
    ]
  }

  private func isActive(_ agent: ManagedAgentSnapshot) -> Bool {
    switch agent {
    case .terminal(let snapshot):
      snapshot.status.isActive
    case .codex(let snapshot):
      snapshot.status.isActive
    case .acp(let snapshot):
      snapshot.status == .active
    }
  }

  private func isBlocked(_ agent: ManagedAgentSnapshot) -> Bool {
    switch agent {
    case .terminal(let snapshot):
      snapshot.status == .failed
    case .codex(let snapshot):
      snapshot.status == .waitingApproval || !snapshot.pendingApprovals.isEmpty
    case .acp(let snapshot):
      snapshot.pendingPermissions > 0 || snapshot.status == .awaitingReview
    }
  }

  private func taskBoardSeverity(_ item: TaskBoardItem) -> MobileAttentionSeverity {
    switch item.priority {
    case .critical:
      .critical
    case .high, .medium, .low:
      .warning
    }
  }

  private func taskBoardSubtitle(_ item: TaskBoardItem) -> String {
    let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
    let subject = body.isEmpty ? item.title : body
    let trimmedSubject =
      subject.count > 140
      ? "\(subject.prefix(137))..."
      : subject
    return "\(item.title) - \(item.status.title) - \(item.priority.title). \(trimmedSubject)"
  }

  private func parseDate(_ value: String?, fallback: Date) -> Date {
    guard let value, !value.isEmpty else {
      return fallback
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) {
      return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value) ?? fallback
  }
}

private struct MobileRelayTaskBoardFetchResult: Sendable {
  var items: [TaskBoardItem]
  var attention: MobileAttentionItem?

  init(items: [TaskBoardItem], attention: MobileAttentionItem? = nil) {
    self.items = items
    self.attention = attention
  }
}

extension ManagedAgentSnapshot {
  fileprivate var displayTitle: String {
    switch self {
    case .terminal(let snapshot):
      snapshot.agentId
    case .codex(let snapshot):
      snapshot.displayName ?? snapshot.runId
    case .acp(let snapshot):
      snapshot.displayName
    }
  }
}

private struct MobileRelayReviewFetchResult: Sendable {
  var reviews: [ReviewItem]
  var attention: MobileAttentionItem?

  init(
    reviews: [ReviewItem],
    attention: MobileAttentionItem? = nil
  ) {
    self.reviews = reviews
    self.attention = attention
  }
}
