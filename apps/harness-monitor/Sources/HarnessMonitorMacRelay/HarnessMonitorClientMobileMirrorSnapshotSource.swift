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
  static let sessionFetchBatchSize = 6
  static let reviewEnrichmentBatchSize = 4
  static let reviewEnrichmentLimit = 24

  let stationID: String
  let stationName: String
  let clientProvider: @Sendable () async -> (any MobileMirrorClient)?
  let reviewsQueryProvider: @Sendable () async -> ReviewsQueryRequest?
  let trustedDeviceProvider: @Sendable () async throws -> [MobileDeviceDescriptor]
  let clientFailureHandler: @Sendable (String) async -> Void
  let secretRedactor = MobileMirrorSecretRedactor()
  let retention: TimeInterval
  let transientUnavailableGrace: TimeInterval
  var revision: Int64
  var lastSnapshot: MobileMirrorSnapshot?

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

  func liveSnapshot(
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
    let snapshot = makeSnapshotFromFetch(
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

  func incrementRevision() -> Int64 {
    revision += 1
    return revision
  }

  func makeSnapshotFromFetch(
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

  func unavailableSnapshot(
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

  func shouldDeferUnavailableSnapshot(now: Date, error: (any Error)?) -> Bool {
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

  static func isTransientDaemonReachabilityError(_ error: any Error) -> Bool {
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
}
