import Foundation
import HarnessMonitorCore
import HarnessMonitorKit

extension HarnessMonitorClientMobileMirrorSnapshotSource {
  func fetchSessionDetails(
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

  func fetchManagedAgents(
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

  func fetchReviews(
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

  func enrichedMobileReviews(
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

  func reviewsSelectedForEnrichment(
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

  func inferredReviewsQueryRequest(sessions: [SessionSummary]) -> ReviewsQueryRequest? {
    let repositories = MobileRelayGitRepositoryDiscovery.repositories(from: sessions)
    guard !repositories.isEmpty else {
      return nil
    }
    return ReviewsQueryRequest(
      repositories: repositories,
      cacheMaxAgeSeconds: MobileRelayReviewsQueryPreferences.minimumCacheMaxAgeSeconds
    )
  }

  func fetchTaskBoard(
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

  func sortedMobileTaskBoardItems(
    _ items: [MobileTaskBoardSummary]
  ) -> [MobileTaskBoardSummary] {
    items.sorted { lhs, rhs in
      if lhs.needsYou != rhs.needsYou {
        return lhs.needsYou && !rhs.needsYou
      }
      return lhs.updatedAt > rhs.updatedAt
    }
  }

  func preservedAttention(
    matching predicate: (MobileAttentionItem) -> Bool,
    appending warning: MobileAttentionItem
  ) -> [MobileAttentionItem] {
    var attention = lastSnapshot?.attention.filter(predicate) ?? []
    attention.removeAll { $0.id == warning.id }
    attention.append(warning)
    return attention
  }

  func sessionDetailAttentionFallback(
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

  func managedAgentsAttentionFallback(
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
}
