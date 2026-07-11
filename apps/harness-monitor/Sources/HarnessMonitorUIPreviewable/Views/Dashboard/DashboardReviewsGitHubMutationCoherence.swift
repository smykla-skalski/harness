import Foundation
import HarnessMonitorKit

enum DashboardReviewsGitHubChangeDecision: Equatable {
  case refreshAll
  case waitForTargetedRefresh
  case acknowledge(revision: UInt64)
}

enum DashboardReviewsGitHubMutationCompletion: Equatable {
  case none
  case refreshAll
  case acknowledge(revision: UInt64)
}

enum DashboardReviewsGitHubMutationConfirmation: Equatable {
  case confirmed
  case discarded
  case refreshAll
}

struct DashboardReviewsGitHubMutationRefreshCoordinator {
  struct Token: Hashable, Sendable {
    fileprivate let value: UInt64
  }

  private enum RefreshState {
    case pending
    case succeeded
  }

  private struct PendingMutation {
    let baselineRevision: UInt64
    let operations: Set<String>
    let expectedRevisionCount: UInt64
    let expiresAt: Date
    var refreshState: RefreshState = .pending
    var matchedRevision: UInt64?
    var confirmedRevision: UInt64?
  }

  private static let retentionInterval: TimeInterval = 180

  private var nextToken: UInt64 = 0
  private var pendingMutations: [Token: PendingMutation] = [:]

  mutating func begin(
    baselineRevision: UInt64,
    operations: Set<String>,
    expectedRevisionCount: UInt64,
    now: Date = Date()
  ) -> Token? {
    discardExpiredUnmatched(at: now)
    guard !operations.isEmpty, expectedRevisionCount > 0 else { return nil }
    nextToken &+= 1
    let token = Token(value: nextToken)
    pendingMutations[token] = PendingMutation(
      baselineRevision: baselineRevision,
      operations: operations,
      expectedRevisionCount: expectedRevisionCount,
      expiresAt: now.addingTimeInterval(Self.retentionInterval)
    )
    return token
  }

  mutating func changeDecision(
    for change: GitHubDataChangedPayload,
    now: Date = Date()
  ) -> DashboardReviewsGitHubChangeDecision {
    guard !discardExpired(at: now) else { return .refreshAll }
    let candidateTokens = pendingMutations.compactMap { token, mutation in
      mutation.baselineRevision < change.revision
        && mutation.operations.contains(change.operation)
        ? token
        : nil
    }
    guard !candidateTokens.isEmpty else { return .refreshAll }

    for token in candidateTokens {
      guard var mutation = pendingMutations[token] else { continue }
      let expectedRevision = mutation.baselineRevision.addingReportingOverflow(
        mutation.expectedRevisionCount
      )
      if expectedRevision.overflow
        || change.revision > expectedRevision.partialValue
        || mutation.confirmedRevision.isSomeAndLess(than: change.revision)
      {
        for candidateToken in candidateTokens {
          pendingMutations.removeValue(forKey: candidateToken)
        }
        return .refreshAll
      }
      mutation.matchedRevision = max(mutation.matchedRevision ?? 0, change.revision)
      pendingMutations[token] = mutation
    }
    guard
      candidateTokens.allSatisfy({ token in
        pendingMutations[token]?.confirmedRevision == change.revision
          && pendingMutations[token]?.refreshState == .succeeded
      })
    else {
      return .waitForTargetedRefresh
    }
    for token in candidateTokens {
      pendingMutations.removeValue(forKey: token)
    }
    return .acknowledge(revision: change.revision)
  }

  mutating func confirm(
    _ token: Token,
    endingRevision: UInt64,
    appliedRevisionCount: UInt64,
    now: Date = Date()
  ) -> DashboardReviewsGitHubMutationConfirmation {
    guard !discardExpired(at: now) else {
      pendingMutations.removeValue(forKey: token)
      return .refreshAll
    }
    guard var mutation = pendingMutations[token] else { return .discarded }
    let expectedRevision = mutation.baselineRevision.addingReportingOverflow(
      mutation.expectedRevisionCount
    )
    guard appliedRevisionCount == mutation.expectedRevisionCount,
      !expectedRevision.overflow,
      endingRevision == expectedRevision.partialValue
    else {
      pendingMutations.removeValue(forKey: token)
      return mutation.matchedRevision == nil ? .discarded : .refreshAll
    }
    if let matchedRevision = mutation.matchedRevision,
      matchedRevision > endingRevision
    {
      pendingMutations.removeValue(forKey: token)
      return .refreshAll
    }
    mutation.confirmedRevision = endingRevision
    pendingMutations[token] = mutation
    return .confirmed
  }

  mutating func targetedRefreshSucceeded(
    for token: Token,
    now: Date = Date()
  ) -> DashboardReviewsGitHubMutationCompletion {
    guard !discardExpired(at: now) else {
      pendingMutations.removeValue(forKey: token)
      return .refreshAll
    }
    guard var mutation = pendingMutations[token] else { return .none }
    mutation.refreshState = .succeeded
    pendingMutations[token] = mutation
    guard let revision = mutation.matchedRevision else { return .none }
    return resolveSucceededMutations(matching: revision)
  }

  mutating func targetedRefreshFailed(
    for token: Token,
    now: Date = Date()
  ) -> DashboardReviewsGitHubMutationCompletion {
    guard !discardExpired(at: now) else {
      pendingMutations.removeValue(forKey: token)
      return .refreshAll
    }
    guard let mutation = pendingMutations.removeValue(forKey: token) else { return .none }
    return mutation.matchedRevision == nil ? .none : .refreshAll
  }

  mutating func discardAcknowledgedChanges(
    upTo revision: UInt64,
    now: Date = Date()
  ) {
    pendingMutations = pendingMutations.filter { _, mutation in
      guard let matchedRevision = mutation.matchedRevision else { return true }
      return matchedRevision > revision
    }
    discardExpiredUnmatched(at: now)
  }

  private mutating func resolveSucceededMutations(
    matching revision: UInt64
  ) -> DashboardReviewsGitHubMutationCompletion {
    let matchingTokens = pendingMutations.compactMap { token, mutation in
      mutation.matchedRevision == revision ? token : nil
    }
    guard !matchingTokens.isEmpty else { return .none }
    guard
      matchingTokens.allSatisfy({ token in
        pendingMutations[token]?.confirmedRevision == revision
          && pendingMutations[token]?.refreshState == .succeeded
      })
    else {
      return .none
    }
    for token in matchingTokens {
      pendingMutations.removeValue(forKey: token)
    }
    return .acknowledge(revision: revision)
  }

  private mutating func discardExpired(at now: Date) -> Bool {
    let discardedMatchedMutation = pendingMutations.values.contains { mutation in
      mutation.expiresAt <= now && mutation.matchedRevision != nil
    }
    pendingMutations = pendingMutations.filter { _, mutation in
      mutation.expiresAt > now
    }
    return discardedMatchedMutation
  }

  private mutating func discardExpiredUnmatched(at now: Date) {
    pendingMutations = pendingMutations.filter { _, mutation in
      mutation.expiresAt > now || mutation.matchedRevision != nil
    }
  }
}

extension Optional where Wrapped: Comparable {
  fileprivate func isSomeAndLess(than value: Wrapped) -> Bool {
    guard let self else { return false }
    return self < value
  }
}

func dashboardReviewsGitHubMutationOperations(
  for action: ReviewActionKind
) -> Set<String> {
  switch action {
  case .approve:
    ["reviews.approve"]
  case .merge, .autoMerge:
    ["task_board.github.merge_pull_request"]
  case .rerunChecks:
    ["reviews.rerequest_checks"]
  case .addLabel:
    ["task_board.github.replace_labels"]
  case .autoApprove:
    ["reviews.auto_approve"]
  case .comment:
    ["reviews.comment"]
  case .requestReview:
    ["task_board.github.request_reviewers"]
  case .unknown:
    []
  }
}

func dashboardReviewsMutationFullyApplied(
  _ response: ReviewsActionResponse,
  expectedResultCount: Int
) -> Bool {
  response.results.count == expectedResultCount
    && response.results.allSatisfy { $0.outcome == .applied }
}

func dashboardReviewsExpectedGitHubRevisionCount(
  action: ReviewActionKind,
  items: [ReviewItem]
) -> UInt64 {
  switch action {
  case .rerunChecks:
    items.reduce(into: UInt64(0)) { count, item in
      count += UInt64(item.rerunnableCheckSuiteIDs.count)
    }
  case .approve, .merge, .addLabel, .autoApprove, .autoMerge, .comment, .requestReview:
    UInt64(items.count)
  case .unknown:
    0
  }
}

@MainActor
extension DashboardReviewsRouteView {
  func beginTargetedGitHubMutation(
    action: ReviewActionKind,
    expectedRevisionCount: UInt64
  ) -> DashboardReviewsGitHubMutationRefreshCoordinator.Token? {
    routeStateStorage.githubMutationRefreshCoordinator.begin(
      baselineRevision: store.contentUI.dashboard.githubDataRevision,
      operations: dashboardReviewsGitHubMutationOperations(for: action),
      expectedRevisionCount: expectedRevisionCount
    )
  }

  func confirmTargetedGitHubMutation(
    _ token: DashboardReviewsGitHubMutationRefreshCoordinator.Token?,
    appliedRevisionCount: UInt64?,
    using client: any HarnessMonitorClientProtocol
  ) async -> DashboardReviewsGitHubMutationRefreshCoordinator.Token? {
    guard let token, let appliedRevisionCount else {
      targetedGitHubMutationFailed(token)
      return nil
    }
    let endingRevision: UInt64?
    do {
      endingRevision = try await client.githubStatus().dataRevision
    } catch {
      targetedGitHubMutationFailed(token)
      return nil
    }
    guard let endingRevision else {
      targetedGitHubMutationFailed(token)
      return nil
    }
    let confirmation = routeStateStorage.githubMutationRefreshCoordinator.confirm(
      token,
      endingRevision: endingRevision,
      appliedRevisionCount: appliedRevisionCount
    )
    switch confirmation {
    case .confirmed:
      return token
    case .discarded:
      return nil
    case .refreshAll:
      await reloadForCurrentGitHubRevision()
      return nil
    }
  }

  func currentGitHubChangeDecision() -> DashboardReviewsGitHubChangeDecision? {
    let dashboard = store.contentUI.dashboard
    guard let change = dashboard.latestGitHubDataChange,
      change.revision == dashboard.githubDataRevision
    else {
      return nil
    }
    return routeStateStorage.githubMutationRefreshCoordinator.changeDecision(for: change)
  }

  func targetedGitHubMutationFailed(
    _ token: DashboardReviewsGitHubMutationRefreshCoordinator.Token?
  ) {
    guard let token else { return }
    let completion =
      routeStateStorage.githubMutationRefreshCoordinator
      .targetedRefreshFailed(for: token)
    guard completion == .refreshAll else { return }
    Task { await reloadForCurrentGitHubRevision() }
  }

  func targetedGitHubMutationRefreshFinished(
    _ token: DashboardReviewsGitHubMutationRefreshCoordinator.Token?,
    succeeded: Bool
  ) async {
    guard let token else { return }
    let completion =
      if succeeded {
        routeStateStorage.githubMutationRefreshCoordinator
          .targetedRefreshSucceeded(for: token)
      } else {
        routeStateStorage.githubMutationRefreshCoordinator
          .targetedRefreshFailed(for: token)
      }
    switch completion {
    case .none:
      break
    case .refreshAll:
      await reloadForCurrentGitHubRevision()
    case .acknowledge(let revision):
      guard store.contentUI.dashboard.githubDataRevision == revision else {
        await reloadForCurrentGitHubRevision()
        return
      }
      routeLoadedGitHubDataRevision = revision
      routeStateStorage.githubMutationRefreshCoordinator
        .discardAcknowledgedChanges(upTo: revision)
    }
  }
}
