import Foundation
import HarnessMonitorCore
import HarnessMonitorKit

public protocol MobileMirrorClient: Sendable {
  func health() async throws -> HealthResponse
  func sessions() async throws -> [SessionSummary]
  func sessionDetail(id: String, scope: String?) async throws -> SessionDetail
  func managedAgents(sessionID: String) async throws -> ManagedAgentListResponse
  func queryReviews(request: ReviewsQueryRequest) async throws -> ReviewsQueryResponse
  func listReviewFiles(request: ReviewsFilesListRequest) async throws -> ReviewsFilesListResponse
  func fetchReviewTimeline(request: ReviewsTimelineRequest) async throws -> ReviewsTimelineResponse
  func taskBoardItems(status: TaskBoardStatus?) async throws -> [TaskBoardItem]
}

extension MobileMirrorClient {
  public func listReviewFiles(
    request _: ReviewsFilesListRequest
  ) async throws -> ReviewsFilesListResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Review files unavailable")
  }

  public func fetchReviewTimeline(
    request _: ReviewsTimelineRequest
  ) async throws -> ReviewsTimelineResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Review timeline unavailable")
  }
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

  public func listReviewFiles(
    request: ReviewsFilesListRequest
  ) async throws -> ReviewsFilesListResponse {
    try await client.listReviewFiles(request: request)
  }

  public func fetchReviewTimeline(
    request: ReviewsTimelineRequest
  ) async throws -> ReviewsTimelineResponse {
    try await client.fetchReviewTimeline(request: request)
  }

  public func taskBoardItems(status: TaskBoardStatus?) async throws -> [TaskBoardItem] {
    try await client.taskBoardItems(status: status)
  }
}

public struct MobileMirrorSnapshotUnavailable: Error, LocalizedError, Equatable {
  public var message: String

  public init(message: String) {
    self.message = message
  }

  public var errorDescription: String? {
    message
  }
}

public actor HarnessMonitorClientMobileMirrorSnapshotSource: MobileMirrorSnapshotSource {
  private static let sessionFetchBatchSize = 6
  private static let reviewEnrichmentBatchSize = 4
  private static let reviewEnrichmentLimit = 24

  private let stationID: String
  private let stationName: String
  private let clientProvider: @Sendable () async -> (any MobileMirrorClient)?
  private let reviewsQueryProvider: @Sendable () async -> ReviewsQueryRequest?
  private let trustedDeviceProvider: @Sendable () async throws -> [MobileDeviceDescriptor]
  private let clientFailureHandler: @Sendable (String) async -> Void
  private let secretRedactor = MobileMirrorSecretRedactor()
  private let retention: TimeInterval
  private let transientUnavailableGrace: TimeInterval
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
    clientFailureHandler: @escaping @Sendable (String) async -> Void = { _ in },
    initialRevision: Int64 = 0,
    retention: TimeInterval = 7 * 24 * 60 * 60,
    transientUnavailableGrace: TimeInterval = 60
  ) {
    self.stationID = stationID
    self.stationName = stationName
    self.clientProvider = clientProvider
    self.reviewsQueryProvider = reviewsQueryProvider
    self.trustedDeviceProvider = trustedDeviceProvider
    self.clientFailureHandler = clientFailureHandler
    self.revision = initialRevision
    self.retention = retention
    self.transientUnavailableGrace = transientUnavailableGrace
  }

  public func makeSnapshot(now: Date) async throws -> MobileMirrorSnapshot {
    let nextRevision = incrementRevision()
    guard let client = await clientProvider() else {
      let message = "Mac relay is waiting for the Harness daemon connection."
      await clientFailureHandler(message)
      if shouldDeferUnavailableSnapshot(now: now, error: nil) {
        throw MobileMirrorSnapshotUnavailable(message: message)
      }
      return try await unavailableSnapshot(
        now: now,
        revision: nextRevision,
        message: message
      )
    }

    var refreshError: (any Error)?
    do {
      return try await liveSnapshot(client: client, now: now, revision: nextRevision)
    } catch {
      refreshError = error
    }

    let firstError = refreshError ?? MobileMirrorSnapshotUnavailable(message: "Unknown error")
    await clientFailureHandler(String(describing: firstError))
    if Self.isTransientDaemonReachabilityError(firstError),
      let retryClient = await clientProvider()
    {
      do {
        return try await liveSnapshot(client: retryClient, now: now, revision: nextRevision)
      } catch {
        refreshError = error
      }
    }

    let finalError = refreshError ?? firstError
    if shouldDeferUnavailableSnapshot(now: now, error: finalError) {
      throw MobileMirrorSnapshotUnavailable(
        message: "Mac relay could not refresh Monitor state: \(String(describing: finalError))"
      )
    }
    return try await unavailableSnapshot(
      now: now,
      revision: nextRevision,
      message: "Mac relay could not refresh Monitor state: \(String(describing: finalError))"
    )
  }

  private func liveSnapshot(
    client: any MobileMirrorClient,
    now: Date,
    revision: Int64
  ) async throws -> MobileMirrorSnapshot {
    let health = try await client.health()
    let sessions = try await client.sessions()
    let sessionDetailFetch = await fetchSessionDetails(
      client: client,
      sessions: sessions,
      now: now
    )
    let managedAgentsFetch = await fetchManagedAgents(
      client: client,
      sessions: sessions,
      now: now
    )
    let reviewFetch = await fetchReviews(client: client, sessions: sessions, now: now)
    let taskBoardFetch = await fetchTaskBoard(client: client, now: now)
    let trustedDevices = try await trustedDeviceProvider()
    let snapshot = makeSnapshot(
      now: now,
      revision: revision,
      health: health,
      sessions: sessions,
      sessionDetailFetch: sessionDetailFetch,
      managedAgentsFetch: managedAgentsFetch,
      reviews: reviewFetch.reviews,
      mobileReviews: reviewFetch.mobileReviews,
      reviewAttentionFallback: reviewFetch.attentionFallback,
      taskBoardItems: taskBoardFetch.items,
      mobileTaskBoardItems: taskBoardFetch.mobileItems,
      taskBoardAttentionFallback: taskBoardFetch.attentionFallback,
      trustedDevices: trustedDevices
    )
    lastSnapshot = snapshot
    return snapshot
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
    sessionDetailFetch: MobileRelaySessionDetailFetchResult,
    managedAgentsFetch: MobileRelayManagedAgentsFetchResult,
    reviews: [ReviewItem],
    mobileReviews: [MobileReviewSummary],
    reviewAttentionFallback: [MobileAttentionItem],
    taskBoardItems: [TaskBoardItem],
    mobileTaskBoardItems: [MobileTaskBoardSummary]?,
    taskBoardAttentionFallback: [MobileAttentionItem],
    trustedDevices: [MobileDeviceDescriptor]
  ) -> MobileMirrorSnapshot {
    let detailsBySessionID = sessionDetailFetch.detailsBySessionID
    let agentsBySessionID = managedAgentsFetch.agentsBySessionID
    var attention: [MobileAttentionItem] = []
    attention.append(
      contentsOf: acpPermissionAttention(
        sessions: sessions,
        agentsBySessionID: agentsBySessionID,
        revision: revision,
        now: now
      ))
    if reviewAttentionFallback.isEmpty {
      attention.append(
        contentsOf: reviewAttention(
          reviews: reviews,
          revision: revision,
          now: now
        ))
    } else {
      attention.append(contentsOf: reviewAttentionFallback)
    }
    attention.append(contentsOf: sessionDetailFetch.attentionFallback)
    attention.append(
      contentsOf: sessionTaskAttention(
        sessions: sessions,
        detailsBySessionID: detailsBySessionID,
        revision: revision,
        now: now
      ))
    if taskBoardAttentionFallback.isEmpty {
      attention.append(
        contentsOf: taskBoardAttention(
          items: taskBoardItems,
          revision: revision,
          now: now
        ))
    } else {
      attention.append(contentsOf: taskBoardAttentionFallback)
    }
    attention.append(contentsOf: managedAgentsFetch.attentionFallback)
    attention.append(
      contentsOf: blockedAgentAttention(
        sessions: sessions,
        agentsBySessionID: agentsBySessionID,
        revision: revision,
        now: now
      ))

    let mobileSessions = sessions.map { session in
      let agents = agentsBySessionID[session.sessionId] ?? []
      var mobileSession = mobileSession(
        session,
        agents: agents,
        now: now
      )
      if managedAgentsFetch.failedSessionIDs.contains(session.sessionId),
        let previousSession = lastSnapshot?.sessions.first(where: { $0.id == session.sessionId })
      {
        mobileSession.agents = previousSession.agents
        mobileSession.activeAgentCount = previousSession.activeAgentCount
        mobileSession.blockedAgentCount = previousSession.blockedAgentCount
      }
      return mobileSession
    }
    let mobileTaskBoardItems =
      mobileTaskBoardItems
      ?? sortedMobileTaskBoardItems(taskBoardItems.map { mobileTaskBoardItem($0, now: now) })
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

    return redactedSnapshot(
      MobileMirrorSnapshot(
        revision: revision,
        generatedAt: now,
        expiresAt: now.addingTimeInterval(retention),
        stations: [station],
        attention: attention,
        sessions: mobileSessions,
        reviews: mobileReviews,
        taskBoardItems: sortedMobileTaskBoardItems(mobileTaskBoardItems),
        commands: lastSnapshot?.commands ?? [],
        trustedDevices: trustedDevices
      )
    )
  }

  private func unavailableSnapshot(
    now: Date,
    revision: Int64,
    message: String
  ) async throws -> MobileMirrorSnapshot {
    guard let previousSnapshot = lastSnapshot else {
      throw MobileMirrorSnapshotUnavailable(message: message)
    }
    let trustedDevices = try await trustedDeviceProvider()
    let previousStation = previousSnapshot.station(id: stationID)
    let activeSessionCount = previousStation?.activeSessionCount ?? 0
    let previousCommandQueueCount = previousStation?.commandQueueCount ?? 0
    var attention = previousSnapshot.attention
    attention.removeAll { $0.id == "station-health-\(stationID)" }
    attention.append(
      MobileAttentionItem(
        id: "station-health-\(stationID)",
        stationID: stationID,
        kind: .stationHealth,
        severity: .warning,
        title: "Mac relay is stale",
        subtitle: "\(message) Showing the last mirrored Monitor state.",
        updatedAt: now
      )
    )
    let station = MobileStationSummary(
      id: stationID,
      displayName: stationName,
      state: .stale,
      lastSeenAt: previousStation?.lastSeenAt ?? now,
      activeSessionCount: activeSessionCount,
      needsYouCount: attention.count { $0.needsUserAction },
      commandQueueCount: previousCommandQueueCount,
      defaultStation: true
    )

    let snapshot = redactedSnapshot(
      MobileMirrorSnapshot(
        revision: revision,
        generatedAt: now,
        expiresAt: now.addingTimeInterval(retention),
        stations: [station],
        attention: attention,
        sessions: previousSnapshot.sessions,
        reviews: previousSnapshot.reviews,
        taskBoardItems: previousSnapshot.taskBoardItems,
        commands: previousSnapshot.commands,
        trustedDevices: trustedDevices
      )
    )
    lastSnapshot = snapshot
    return snapshot
  }

  private func shouldDeferUnavailableSnapshot(now: Date, error: (any Error)?) -> Bool {
    guard transientUnavailableGrace > 0, let lastSnapshot else {
      return false
    }
    guard now.timeIntervalSince(lastSnapshot.generatedAt) < transientUnavailableGrace else {
      return false
    }
    guard let error else {
      return true
    }
    return Self.isTransientDaemonReachabilityError(error)
  }

  private static func isTransientDaemonReachabilityError(_ error: any Error) -> Bool {
    let message = String(describing: error).lowercased()
    let localized = error.localizedDescription.lowercased()
    return [message, localized].contains { description in
      description.contains("not connected")
        || description.contains("connection closed")
        || description.contains("connection refused")
        || description.contains("network connection was lost")
        || description.contains("manifest is missing")
        || description.contains("manifest missing")
        || description.contains("could not connect")
        || description.contains("isn't reachable")
        || description.contains("is not reachable")
    }
  }

  private func fetchSessionDetails(
    client: any MobileMirrorClient,
    sessions: [SessionSummary],
    now: Date
  ) async -> MobileRelaySessionDetailFetchResult {
    var detailsBySessionID: [String: SessionDetail] = [:]
    var failedSessionIDs: Set<String> = []
    let activeSessions = sessions.filter { $0.status != .ended }
    for batch in batches(activeSessions, size: Self.sessionFetchBatchSize) {
      await withTaskGroup(of: MobileRelaySessionDetailFetchOutcome.self) { group in
        for session in batch {
          group.addTask {
            do {
              return MobileRelaySessionDetailFetchOutcome(
                sessionID: session.sessionId,
                detail: try await client.sessionDetail(id: session.sessionId, scope: "core")
              )
            } catch {
              return MobileRelaySessionDetailFetchOutcome(
                sessionID: session.sessionId,
                detail: nil
              )
            }
          }
        }
        for await outcome in group {
          if let detail = outcome.detail {
            detailsBySessionID[outcome.sessionID] = detail
          } else {
            failedSessionIDs.insert(outcome.sessionID)
          }
        }
      }
    }
    return MobileRelaySessionDetailFetchResult(
      detailsBySessionID: detailsBySessionID,
      failedSessionIDs: failedSessionIDs,
      attentionFallback: sessionDetailAttentionFallback(
        failedSessionIDs: failedSessionIDs, now: now
      )
    )
  }

  private func fetchManagedAgents(
    client: any MobileMirrorClient,
    sessions: [SessionSummary],
    now: Date
  ) async -> MobileRelayManagedAgentsFetchResult {
    var agentsBySessionID: [String: [ManagedAgentSnapshot]] = [:]
    var failedSessionIDs: Set<String> = []
    let activeSessions = sessions.filter { $0.status != .ended }
    for batch in batches(activeSessions, size: Self.sessionFetchBatchSize) {
      await withTaskGroup(of: MobileRelayManagedAgentsFetchOutcome.self) { group in
        for session in batch {
          group.addTask {
            do {
              return MobileRelayManagedAgentsFetchOutcome(
                sessionID: session.sessionId,
                agents: try await client.managedAgents(sessionID: session.sessionId).agents
              )
            } catch {
              return MobileRelayManagedAgentsFetchOutcome(
                sessionID: session.sessionId,
                agents: nil
              )
            }
          }
        }
        for await outcome in group {
          if let agents = outcome.agents {
            agentsBySessionID[outcome.sessionID] = agents
          } else {
            failedSessionIDs.insert(outcome.sessionID)
          }
        }
      }
    }
    return MobileRelayManagedAgentsFetchResult(
      agentsBySessionID: agentsBySessionID,
      failedSessionIDs: failedSessionIDs,
      attentionFallback: managedAgentsAttentionFallback(
        failedSessionIDs: failedSessionIDs, now: now
      )
    )
  }

  private func fetchReviews(
    client: any MobileMirrorClient,
    sessions: [SessionSummary],
    now: Date
  ) async -> MobileRelayReviewFetchResult {
    guard
      let request = await reviewsQueryProvider()
        ?? inferredReviewsQueryRequest(sessions: sessions)
    else {
      return MobileRelayReviewFetchResult(
        reviews: [],
        mobileReviews: [],
        attentionFallback: [
          reviewsUnavailableAttention(
            title: "Reviews are not configured",
            subtitle: "Configure Review repositories on the Mac to mirror pull requests.",
            severity: .info,
            now: now
          )
        ]
      )
    }
    do {
      let response = try await client.queryReviews(
        request: request
      )
      let mobileReviews = await enrichedMobileReviews(
        response.items,
        client: client,
        now: now
      )
      return MobileRelayReviewFetchResult(reviews: response.items, mobileReviews: mobileReviews)
    } catch {
      return MobileRelayReviewFetchResult(
        reviews: [],
        mobileReviews: lastSnapshot?.reviews ?? [],
        attentionFallback: preservedAttention(
          matching: { $0.kind == .pullRequest },
          appending: reviewsUnavailableAttention(
            title: "Reviews mirror failed",
            subtitle:
              "The Mac could not refresh Reviews. Showing the last mirrored review state.",
            severity: .warning,
            now: now
          )
        )
      )
    }
  }

  private func enrichedMobileReviews(
    _ reviews: [ReviewItem],
    client: any MobileMirrorClient,
    now: Date
  ) async -> [MobileReviewSummary] {
    let enrichmentCandidates = reviewsSelectedForEnrichment(reviews, now: now)
    var enrichmentsByID: [String: MobileRelayReviewEnrichment] = [:]
    for batch in batches(enrichmentCandidates, size: Self.reviewEnrichmentBatchSize) {
      await withTaskGroup(of: MobileRelayReviewEnrichment.self) { group in
        for review in batch {
          group.addTask {
            async let files = try? client.listReviewFiles(
              request: ReviewsFilesListRequest(pullRequestID: review.pullRequestID)
            )
            async let timeline = try? client.fetchReviewTimeline(
              request: ReviewsTimelineRequest(
                pullRequestId: review.pullRequestID,
                pageSize: 5,
                pullRequestUpdatedAt: review.updatedAt
              )
            )
            let filesResponse = await files
            let timelineResponse = await timeline
            return MobileRelayReviewEnrichment(
              review: review,
              filesResponse: filesResponse,
              timelineResponse: timelineResponse
            )
          }
        }
        for await enrichment in group {
          enrichmentsByID[enrichment.review.pullRequestID] = enrichment
        }
      }
    }
    return reviews.map { review in
      guard let enrichment = enrichmentsByID[review.pullRequestID] else {
        return mobileReview(review, now: now)
      }
      return mobileReview(
        enrichment.review,
        filesResponse: enrichment.filesResponse,
        timelineResponse: enrichment.timelineResponse,
        now: now
      )
    }
  }

  private func reviewsSelectedForEnrichment(
    _ reviews: [ReviewItem],
    now: Date
  ) -> [ReviewItem] {
    Array(
      reviews
        .sorted { lhs, rhs in
          let lhsNeedsAttention = needsReviewAttention(lhs)
          let rhsNeedsAttention = needsReviewAttention(rhs)
          if lhsNeedsAttention != rhsNeedsAttention {
            return lhsNeedsAttention && !rhsNeedsAttention
          }
          return parseDate(lhs.updatedAt, fallback: now) > parseDate(rhs.updatedAt, fallback: now)
        }
        .prefix(Self.reviewEnrichmentLimit)
    )
  }

  private func inferredReviewsQueryRequest(sessions: [SessionSummary]) -> ReviewsQueryRequest? {
    let repositories = MobileRelayGitRepositoryDiscovery.repositories(from: sessions)
    guard !repositories.isEmpty else {
      return nil
    }
    return ReviewsQueryRequest(
      repositories: repositories,
      cacheMaxAgeSeconds: MobileRelayReviewsQueryPreferences.minimumCacheMaxAgeSeconds
    )
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
        mobileItems: lastSnapshot?.taskBoardItems ?? [],
        attentionFallback: preservedAttention(
          matching: isTaskBoardMirrorAttention,
          appending: MobileAttentionItem(
            id: "task-board-unavailable-\(stationID)",
            stationID: stationID,
            kind: .stationHealth,
            severity: .warning,
            title: "Task board mirror failed",
            subtitle:
              "The Mac could not refresh task-board items. Showing the last mirrored task-board state.",
            updatedAt: now,
            commandKind: .refresh,
            target: MobileCommandTarget(
              stationID: stationID,
              targetRevision: revision
            ),
            commandPayload: ["scope": "taskBoard"]
          )
        )
      )
    }
  }

  private func sortedMobileTaskBoardItems(
    _ items: [MobileTaskBoardSummary]
  ) -> [MobileTaskBoardSummary] {
    items.sorted { lhs, rhs in
      if lhs.needsYou != rhs.needsYou {
        return lhs.needsYou && !rhs.needsYou
      }
      return lhs.updatedAt > rhs.updatedAt
    }
  }

  private func preservedAttention(
    matching predicate: (MobileAttentionItem) -> Bool,
    appending warning: MobileAttentionItem
  ) -> [MobileAttentionItem] {
    var attention = lastSnapshot?.attention.filter(predicate) ?? []
    attention.removeAll { $0.id == warning.id }
    attention.append(warning)
    return attention
  }

  private func sessionDetailAttentionFallback(
    failedSessionIDs: Set<String>,
    now: Date
  ) -> [MobileAttentionItem] {
    guard !failedSessionIDs.isEmpty else {
      return []
    }
    return preservedAttention(
      matching: { item in
        guard item.id.hasPrefix("session-task-"),
          let sessionID = item.target?.sessionID
        else {
          return false
        }
        return failedSessionIDs.contains(sessionID)
      },
      appending: staleSourceAttention(
        id: "session-details-unavailable-\(stationID)",
        title: "Session details mirror is stale",
        subtitle:
          "The Mac could not refresh some session tasks. Showing the last mirrored session-task state.",
        now: now
      )
    )
  }

  private func managedAgentsAttentionFallback(
    failedSessionIDs: Set<String>,
    now: Date
  ) -> [MobileAttentionItem] {
    guard !failedSessionIDs.isEmpty else {
      return []
    }
    return preservedAttention(
      matching: { item in
        guard let sessionID = item.target?.sessionID else {
          return false
        }
        return failedSessionIDs.contains(sessionID)
          && (item.kind == .acpDecision || item.kind == .blockedAgent)
      },
      appending: staleSourceAttention(
        id: "managed-agents-unavailable-\(stationID)",
        title: "Agent mirror is stale",
        subtitle:
          "The Mac could not refresh some agents. Showing the last mirrored agent state.",
        now: now
      )
    )
  }

  private func staleSourceAttention(
    id: String,
    title: String,
    subtitle: String,
    now: Date
  ) -> MobileAttentionItem {
    MobileAttentionItem(
      id: id,
      stationID: stationID,
      kind: .stationHealth,
      severity: .warning,
      title: redacted(title),
      subtitle: redacted(subtitle),
      updatedAt: now,
      commandKind: .refresh,
      target: MobileCommandTarget(
        stationID: stationID,
        targetRevision: revision
      ),
      commandPayload: ["scope": "mobileMirror"]
    )
  }

  private func isTaskBoardMirrorAttention(_ item: MobileAttentionItem) -> Bool {
    item.kind == .taskBoard
      && (item.id.hasPrefix("task-board-plan-")
        || item.id.hasPrefix("task-board-needs-you-")
        || item.id.hasPrefix("task-board-blocked-"))
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
      title: redacted(title),
      subtitle: redacted(subtitle),
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
            title: redacted("Permission requested by \(acp.displayName)"),
            subtitle: redacted(
              "\(requestCount) request\(requestCount == 1 ? "" : "s")"
                + " waiting in \(session?.displayTitle ?? batch.sessionId)."
            ),
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
        title: redacted("\(review.repository) #\(review.number) needs you"),
        subtitle: redacted(review.title),
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
          subtitle: redacted(taskBoardSubtitle(item)),
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
          subtitle: redacted(taskBoardSubtitle(item)),
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
          subtitle: redacted(taskBoardSubtitle(item)),
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
      subtitle: redacted(sessionTaskSubtitle(session: session, task: task)),
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
          title: redacted("\(agent.displayTitle) is waiting"),
          subtitle: redacted(session?.displayTitle ?? agent.sessionId),
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
      projectName: redacted(session.projectName),
      title: redacted(session.displayTitle),
      branch: redacted(session.branchRef),
      status: session.status.title,
      activeAgentCount: agents.count(where: isActive),
      blockedAgentCount: agents.count(where: isBlocked),
      lastActivityAt: parseDate(session.lastActivityAt ?? session.updatedAt, fallback: now),
      summary: redacted(session.context),
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
        displayName: redacted("\(snapshot.runtime) \(snapshot.agentId)"),
        family: .terminal,
        status: snapshot.status.title,
        role: nil,
        isActive: snapshot.status.isActive,
        isBlocked: snapshot.status == .failed,
        lastActivityAt: parseDate(snapshot.updatedAt, fallback: now),
        summary: redacted(snapshot.error ?? snapshot.projectDir)
      )
    case .codex(let snapshot):
      let pendingApprovals = snapshot.pendingApprovals.count
      return MobileAgentSummary(
        id: snapshot.managedAgentID,
        stationID: stationID,
        sessionID: snapshot.sessionId,
        displayName: redacted(snapshot.displayName ?? snapshot.runId),
        family: .codex,
        status: snapshot.status.title,
        role: nil,
        isActive: snapshot.status.isActive,
        isBlocked: snapshot.status == .waitingApproval || pendingApprovals > 0
          || snapshot.status == .failed,
        pendingApprovalCount: pendingApprovals,
        lastActivityAt: parseDate(snapshot.updatedAt, fallback: now),
        summary: redacted(
          snapshot.latestSummary ?? snapshot.finalMessage ?? snapshot.error
            ?? snapshot.prompt
        )
      )
    case .acp(let snapshot):
      return MobileAgentSummary(
        id: snapshot.managedAgentID,
        stationID: stationID,
        sessionID: snapshot.sessionId,
        displayName: redacted(snapshot.displayName),
        family: .acp,
        status: snapshot.status.title,
        role: nil,
        isActive: snapshot.status == .active,
        isBlocked: snapshot.pendingPermissions > 0 || snapshot.status == .awaitingReview,
        pendingPermissionCount: snapshot.pendingPermissions,
        lastActivityAt: parseDate(snapshot.updatedAt, fallback: now),
        summary: redacted(snapshot.stderrTail ?? snapshot.projectDir)
      )
    }
  }

  private func mobileReview(
    _ review: ReviewItem,
    filesResponse: ReviewsFilesListResponse? = nil,
    timelineResponse: ReviewsTimelineResponse? = nil,
    now: Date
  ) -> MobileReviewSummary {
    MobileReviewSummary(
      id: review.pullRequestID,
      stationID: stationID,
      repositoryID: review.repositoryID,
      repository: review.repository,
      number: Int(review.number),
      url: redacted(review.url),
      title: redacted(review.title),
      author: redacted(review.authorLogin),
      state: review.state.rawValue,
      checksSummary: review.checkStatus.rawValue,
      headSha: review.headSha,
      mergeable: review.mergeable.rawValue,
      reviewStatus: review.reviewStatus.rawValue,
      checkStatus: review.checkStatus.rawValue,
      policyBlocked: review.policyBlocked,
      isDraft: review.isDraft,
      labels: review.labels.map(redacted),
      checks: review.checks.prefix(6).map(mobileReviewCheck),
      files: (filesResponse?.files ?? []).prefix(8).map(mobileReviewFile),
      activity: (timelineResponse?.entries ?? []).prefix(6).map { entry in
        mobileReviewActivity(entry, now: now)
      },
      additions: review.additions,
      deletions: review.deletions,
      requiredFailedCheckNames: review.requiredFailedCheckNames.map(redacted),
      viewerCanUpdate: review.viewerCanUpdate,
      viewerCanMergeAsAdmin: review.viewerCanMergeAsAdmin,
      filePaginationComplete: filesResponse?.paginationComplete,
      needsYou: needsReviewAttention(review),
      updatedAt: parseDate(review.updatedAt, fallback: now)
    )
  }

  private func mobileTaskBoardItem(
    _ item: TaskBoardItem,
    now: Date
  ) -> MobileTaskBoardSummary {
    MobileTaskBoardSummary(
      id: item.id,
      stationID: stationID,
      title: redacted(item.title),
      bodyPreview: redacted(taskBoardBodyPreview(item)),
      status: item.status.rawValue,
      statusTitle: item.status.title,
      priority: item.priority.rawValue,
      priorityTitle: item.priority.title,
      tags: item.tags.map(redacted),
      projectID: redacted(item.projectId),
      sessionID: item.sessionId,
      workItemID: item.workItemId,
      agentMode: item.agentMode.rawValue,
      needsYou: taskBoardItemNeedsYou(item),
      updatedAt: parseDate(item.updatedAt, fallback: now)
    )
  }

  private func taskBoardBodyPreview(_ item: TaskBoardItem) -> String {
    let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
    let summary = item.planning.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let source = body.isEmpty ? summary : body
    guard source.count > 180 else {
      return source
    }
    return "\(source.prefix(177))..."
  }

  private func taskBoardItemNeedsYou(_ item: TaskBoardItem) -> Bool {
    switch item.status {
    case .planReview, .needsYou, .blocked:
      true
    default:
      false
    }
  }

  private func mobileReviewCheck(_ check: ReviewCheck) -> MobileReviewCheckSnippet {
    MobileReviewCheckSnippet(
      id: redacted(check.id),
      name: redacted(check.name),
      status: check.status.rawValue,
      conclusion: check.conclusion.rawValue,
      checkSuiteID: check.checkSuiteID,
      detailsURL: redacted(check.detailsURL)
    )
  }

  private func mobileReviewFile(_ file: ReviewFile) -> MobileReviewFileSnippet {
    MobileReviewFileSnippet(
      id: redacted(file.id),
      path: redacted(file.path),
      changeType: file.changeType.rawValue,
      additions: file.additions,
      deletions: file.deletions,
      viewedState: file.viewerViewedState.rawValue,
      isBinary: file.isBinary
    )
  }

  private func mobileReviewActivity(
    _ entry: ReviewTimelineEntry,
    now: Date
  ) -> MobileReviewActivitySnippet {
    MobileReviewActivitySnippet(
      id: entry.id,
      kind: entry.kind.rawValue,
      actor: redacted(entry.actor?.login),
      summary: redacted(reviewActivitySummary(entry)),
      recordedAt: parseDate(entry.recordedAt, fallback: now)
    )
  }

  private func reviewActivitySummary(_ entry: ReviewTimelineEntry) -> String {
    switch entry {
    case .issueComment:
      "Commented"
    case .review(let payload):
      "Review \(payload.state.rawValue.replacingOccurrences(of: "_", with: " "))"
    case .reviewThread(let payload):
      payload.isResolved ? "Resolved thread on \(payload.path)" : "Thread on \(payload.path)"
    case .commit(let payload):
      "Commit \(payload.abbreviatedOid): \(payload.messageHeadline)"
    case .headRefForcePushed(let payload):
      "Force-pushed \(payload.beforeAbbreviatedOid) -> \(payload.afterAbbreviatedOid)"
    case .simpleActorEvent(let payload):
      simpleActorEventSummary(payload)
    case .unknown(let payload):
      payload.typename
    }
  }

  private func simpleActorEventSummary(_ payload: SimpleActorEventPayload) -> String {
    switch payload.eventKind {
    case .labeled:
      return "Added label \(payload.label ?? "label")"
    case .unlabeled:
      return "Removed label \(payload.label ?? "label")"
    case .reviewRequested:
      return "Requested review from \(payload.requestedReviewerLogin ?? "reviewer")"
    case .reviewRequestRemoved:
      return "Removed review request for \(payload.requestedReviewerLogin ?? "reviewer")"
    case .renamedTitle:
      return "Renamed title"
    case .merged:
      return "Merged"
    case .closed:
      return "Closed"
    case .reopened:
      return "Reopened"
    case .readyForReview:
      return "Marked ready for review"
    case .convertToDraft:
      return "Converted to draft"
    case .autoMergeEnabled:
      return "Enabled auto-merge"
    case .autoMergeDisabled:
      return "Disabled auto-merge"
    default:
      return payload.eventKind.rawValue.replacingOccurrences(of: "_", with: " ")
    }
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

  private func redacted(_ value: String) -> String {
    secretRedactor.redact(value)
  }

  private func redacted(_ value: String?) -> String? {
    value.map { redacted($0) }
  }

  private func redactedSnapshot(_ snapshot: MobileMirrorSnapshot) -> MobileMirrorSnapshot {
    var snapshot = snapshot
    snapshot.stations = snapshot.stations.map(redactedStation)
    snapshot.attention = snapshot.attention.map(redactedAttention)
    snapshot.sessions = snapshot.sessions.map(redactedSession)
    snapshot.reviews = snapshot.reviews.map(redactedReview)
    snapshot.taskBoardItems = snapshot.taskBoardItems.map(redactedTaskBoardItem)
    snapshot.commands = snapshot.commands.map {
      $0.redactingMobileMirrorSecrets(using: secretRedactor)
    }
    snapshot.stations = stationsWithDerivedNeedsYouCounts(in: snapshot)
    return snapshot
  }

  private func stationsWithDerivedNeedsYouCounts(
    in snapshot: MobileMirrorSnapshot
  ) -> [MobileStationSummary] {
    let countsByStation = Dictionary(
      grouping: snapshot.cockpitAttention.filter(\.needsUserAction),
      by: \.stationID
    ).mapValues(\.count)
    return snapshot.stations.map { station in
      var station = station
      station.needsYouCount = countsByStation[station.id] ?? 0
      return station
    }
  }

  private func redactedStation(_ station: MobileStationSummary) -> MobileStationSummary {
    var station = station
    station.displayName = redacted(station.displayName)
    return station
  }

  private func redactedAttention(_ item: MobileAttentionItem) -> MobileAttentionItem {
    var item = item
    item.title = redacted(item.title)
    item.subtitle = redacted(item.subtitle)
    return item
  }

  private func redactedSession(_ session: MobileSessionSummary) -> MobileSessionSummary {
    var session = session
    session.projectName = redacted(session.projectName)
    session.title = redacted(session.title)
    session.branch = redacted(session.branch)
    session.summary = redacted(session.summary)
    session.agents = session.agents.map(redactedAgent)
    return session
  }

  private func redactedAgent(_ agent: MobileAgentSummary) -> MobileAgentSummary {
    var agent = agent
    agent.displayName = redacted(agent.displayName)
    agent.role = redacted(agent.role)
    agent.summary = redacted(agent.summary)
    return agent
  }

  private func redactedReview(_ review: MobileReviewSummary) -> MobileReviewSummary {
    var review = review
    review.url = redacted(review.url)
    review.title = redacted(review.title)
    review.author = redacted(review.author)
    review.labels = review.labels.map(redacted)
    review.checks = review.checks.map(redactedReviewCheck)
    review.files = review.files.map(redactedReviewFile)
    review.activity = review.activity.map(redactedReviewActivity)
    review.requiredFailedCheckNames = review.requiredFailedCheckNames.map(redacted)
    return review
  }

  private func redactedReviewCheck(
    _ check: MobileReviewCheckSnippet
  ) -> MobileReviewCheckSnippet {
    var check = check
    check.id = redacted(check.id)
    check.name = redacted(check.name)
    check.detailsURL = redacted(check.detailsURL)
    return check
  }

  private func redactedReviewFile(
    _ file: MobileReviewFileSnippet
  ) -> MobileReviewFileSnippet {
    var file = file
    file.id = redacted(file.id)
    file.path = redacted(file.path)
    return file
  }

  private func redactedReviewActivity(
    _ activity: MobileReviewActivitySnippet
  ) -> MobileReviewActivitySnippet {
    var activity = activity
    activity.actor = redacted(activity.actor)
    activity.summary = redacted(activity.summary)
    return activity
  }

  private func redactedTaskBoardItem(
    _ item: MobileTaskBoardSummary
  ) -> MobileTaskBoardSummary {
    var item = item
    item.title = redacted(item.title)
    item.bodyPreview = redacted(item.bodyPreview)
    item.tags = item.tags.map(redacted)
    item.projectID = redacted(item.projectID)
    return item
  }
}

struct MobileMirrorSecretRedactor {
  private struct Rule {
    var expression: NSRegularExpression
    var template: String
  }

  private struct RawRule {
    var pattern: String
    var options: NSRegularExpression.Options
    var template: String
  }

  private let rules: [Rule]

  init() {
    rules = Self.rawRules.map { rule in
      guard
        let expression = try? NSRegularExpression(
          pattern: rule.pattern,
          options: rule.options
        )
      else {
        fatalError("Invalid redaction rule pattern: \(rule.pattern)")
      }
      return Rule(expression: expression, template: rule.template)
    }
  }

  func redact(_ value: String) -> String {
    guard !value.isEmpty else {
      return value
    }
    return rules.reduce(value) { partial, rule in
      let range = NSRange(partial.startIndex..<partial.endIndex, in: partial)
      return rule.expression.stringByReplacingMatches(
        in: partial,
        options: [],
        range: range,
        withTemplate: rule.template
      )
    }
  }

  private static let rawRules: [RawRule] = [
      .init(
        pattern:
          "(?i)(\\b(?:aws_secret_access_key|aws_access_key_id|github_token|gh_token"
          + "|gitlab_token|openai_api_key|anthropic_api_key|api[_-]?key"
          + "|access[_-]?token|refresh[_-]?token|auth[_-]?token|id[_-]?token"
          + "|client[_-]?secret|private[_-]?key|secret|password|passwd|pwd)"
          + "\\b\\s*[:=]\\s*)(\"[^\"]*\"|'[^']*'|[^\\s,;]+)",
        options: [],
        template: "$1[redacted]"
      ),
      .init(
        pattern: "(?i)\\bBearer\\s+[A-Za-z0-9._~+/=-]{8,}",
        options: [],
        template: "Bearer [redacted]"
      ),
      .init(
        pattern: "(?i)(https?://)[^\\s/@]+:[^\\s/@]+@",
        options: [],
        template: "$1[redacted]@"
      ),
      .init(
        pattern: "\\bgithub_pat_[A-Za-z0-9_]{20,}\\b",
        options: [],
        template: "[redacted]"
      ),
      .init(
        pattern: "\\bgh[pousr]_[A-Za-z0-9_]{20,}\\b",
        options: [],
        template: "[redacted]"
      ),
      .init(
        pattern: "\\bglpat-[A-Za-z0-9_-]{20,}\\b",
        options: [],
        template: "[redacted]"
      ),
      .init(
        pattern: "\\bsk-[A-Za-z0-9]{20,}\\b",
        options: [],
        template: "[redacted]"
      ),
      .init(
        pattern: "\\bxox[baprs]-[A-Za-z0-9-]{20,}\\b",
        options: [],
        template: "[redacted]"
      ),
      .init(
        pattern: "\\bAKIA[0-9A-Z]{16}\\b",
        options: [],
        template: "[redacted]"
      ),
      .init(
        pattern:
          "-----BEGIN [^-]*(?:PRIVATE KEY|SECRET|TOKEN)[\\s\\S]*?-----END [^-]*-----",
        options: [.caseInsensitive],
        template: "[redacted]"
      ),
    ]
}

extension MobileCommandRecord {
  func redactingMobileMirrorSecrets(
    using redactor: MobileMirrorSecretRedactor
  ) -> MobileCommandRecord {
    var command = self
    command.title = redactor.redact(command.title)
    command.confirmationText = redactor.redact(command.confirmationText)
    command.auditReason = command.auditReason.map { redactor.redact($0) }
    command.payload = command.payload.mapValues { redactor.redact($0) }
    command.receipt = command.receipt?.redactingMobileMirrorSecrets(using: redactor)
    return command
  }
}

extension MobileCommandReceipt {
  func redactingMobileMirrorSecrets(
    using redactor: MobileMirrorSecretRedactor
  ) -> MobileCommandReceipt {
    var receipt = self
    receipt.message = redactor.redact(receipt.message)
    return receipt
  }
}

private struct MobileRelayTaskBoardFetchResult: Sendable {
  var items: [TaskBoardItem]
  var mobileItems: [MobileTaskBoardSummary]?
  var attentionFallback: [MobileAttentionItem]

  init(
    items: [TaskBoardItem],
    mobileItems: [MobileTaskBoardSummary]? = nil,
    attentionFallback: [MobileAttentionItem] = []
  ) {
    self.items = items
    self.mobileItems = mobileItems
    self.attentionFallback = attentionFallback
  }
}

private struct MobileRelaySessionDetailFetchResult: Sendable {
  var detailsBySessionID: [String: SessionDetail]
  var failedSessionIDs: Set<String>
  var attentionFallback: [MobileAttentionItem]
}

private struct MobileRelaySessionDetailFetchOutcome: Sendable {
  var sessionID: String
  var detail: SessionDetail?
}

private struct MobileRelayManagedAgentsFetchResult: Sendable {
  var agentsBySessionID: [String: [ManagedAgentSnapshot]]
  var failedSessionIDs: Set<String>
  var attentionFallback: [MobileAttentionItem]
}

private struct MobileRelayManagedAgentsFetchOutcome: Sendable {
  var sessionID: String
  var agents: [ManagedAgentSnapshot]?
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
  var mobileReviews: [MobileReviewSummary]
  var attentionFallback: [MobileAttentionItem]

  init(
    reviews: [ReviewItem],
    mobileReviews: [MobileReviewSummary],
    attentionFallback: [MobileAttentionItem] = []
  ) {
    self.reviews = reviews
    self.mobileReviews = mobileReviews
    self.attentionFallback = attentionFallback
  }
}

private struct MobileRelayReviewEnrichment: Sendable {
  var review: ReviewItem
  var filesResponse: ReviewsFilesListResponse?
  var timelineResponse: ReviewsTimelineResponse?
}

private func batches<Element>(_ values: [Element], size: Int) -> [[Element]] {
  guard size > 0, !values.isEmpty else {
    return []
  }
  var result: [[Element]] = []
  result.reserveCapacity((values.count + size - 1) / size)
  var start = values.startIndex
  while start < values.endIndex {
    let end = values.index(start, offsetBy: size, limitedBy: values.endIndex) ?? values.endIndex
    result.append(Array(values[start..<end]))
    start = end
  }
  return result
}
