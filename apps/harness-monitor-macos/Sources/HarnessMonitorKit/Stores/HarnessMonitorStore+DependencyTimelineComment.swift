import Foundation

public enum DependencyUpdateCommentPostOutcome: Sendable, Equatable {
  case posted(optimisticID: String)
  case failed(reason: String)
  case daemonOffline
  case empty
}

extension HarnessMonitorStore {
  /// Sends a new comment to the PR and, ahead of the daemon roundtrip,
  /// appends an optimistic synthetic `IssueComment` entry to the per-PR
  /// timeline view model so the UI reflects the user's action with no
  /// perceivable lag.
  ///
  /// On success the daemon returns the created GitHub comment as a
  /// timeline entry, so the synthetic optimistic id is replaced with
  /// the durable GitHub id. On failure the optimistic entry is removed
  /// and the outcome carries the reason string for the composer to surface.
  public func postDependencyUpdateComment(
    for item: DependencyUpdateItem,
    body: String,
    viewerLogin: String? = nil
  ) async -> DependencyUpdateCommentPostOutcome {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return .empty
    }
    guard let client else {
      return .daemonOffline
    }

    let optimisticID = "optimistic:\(UUID().uuidString)"
    let actor = viewerLogin.map { DependencyUpdateTimelineActor(login: $0) }
    let createdAt = HarnessMonitorStore.optimisticTimestamp()
    let optimisticEntry = DependencyUpdateTimelineEntry.issueComment(
      IssueCommentPayload(
        id: optimisticID,
        createdAt: createdAt,
        actor: actor,
        body: trimmed,
        viewerDidAuthor: true,
        viewerCanEdit: true
      )
    )
    let viewModel = dependencyUpdateTimelineViewModel(for: item.pullRequestID)
    let interval = DependencyTimelinePerf.beginOptimisticInsert(
      pullRequestID: item.pullRequestID
    )
    viewModel.appendOptimistic(optimisticEntry)
    DependencyTimelinePerf.end(interval)

    do {
      let response = try await client.commentDependencyUpdates(
        request: DependencyUpdatesCommentRequest(targets: [item.target], body: trimmed)
      )
      if let landedEntry = response.results.first(where: {
        $0.outcome == .applied && $0.timelineEntry != nil
      })?.timelineEntry {
        viewModel.replaceOptimistic(id: optimisticID, with: landedEntry)
      }
      return .posted(optimisticID: optimisticID)
    } catch {
      viewModel.removeOptimistic(id: optimisticID)
      return .failed(reason: error.localizedDescription)
    }
  }

  @MainActor
  private static let optimisticISOFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  @MainActor
  private static func optimisticTimestamp() -> String {
    optimisticISOFormatter.string(from: Date())
  }
}
