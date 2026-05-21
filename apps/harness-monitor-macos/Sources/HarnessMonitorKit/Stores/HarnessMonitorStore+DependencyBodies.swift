import Foundation

/// View-facing state of a dependency-update PR body fetch keyed by
/// pull-request id. Drives the Description section in the Dependencies
/// detail pane.
public enum DependencyUpdateBodyState: Equatable, Sendable {
  case loading
  case loaded(String)
  case failed(String)
}

/// Identity used by SwiftUI `.task(id:)` to drive the description fetch.
/// Re-fires when the visible PR changes or when the daemon comes back online,
/// so a `.failed("Daemon unavailable")` state recovers automatically without
/// the user having to navigate away and back.
public struct DependencyUpdateBodyTaskKey: Hashable, Sendable {
  public let pullRequestID: String
  public let prUpdatedAt: String
  public let isDaemonOnline: Bool

  public init(item: DependencyUpdateItem, isDaemonOnline: Bool) {
    self.pullRequestID = item.pullRequestID
    self.prUpdatedAt = item.updatedAt
    self.isDaemonOnline = isDaemonOnline
  }
}

extension HarnessMonitorStore {
  /// Ensure the description body for `item` is loaded into
  /// `dependencyUpdateBodyState`. Returns immediately when a fresh entry is
  /// cached (relative to `item.updatedAt`); otherwise marks state as
  /// `.loading`, fetches via the client, persists to disk, and publishes
  /// `.loaded` or `.failed`.
  ///
  /// Concurrent calls for the same pull request id collapse to a single
  /// in-flight fetch.
  public func prepareDependencyUpdateBody(for item: DependencyUpdateItem) async {
    let id = item.pullRequestID
    if let entry = dependencyUpdateBodies.cached(forPullRequestID: id, since: item.updatedAt) {
      dependencyUpdateBodyState[id] = .loaded(entry.body)
      return
    }
    if pendingDependencyUpdateBodyFetches.contains(id) {
      return
    }
    pendingDependencyUpdateBodyFetches.insert(id)
    dependencyUpdateBodyState[id] = .loading
    defer { pendingDependencyUpdateBodyFetches.remove(id) }

    guard let client else {
      dependencyUpdateBodyState[id] = .failed("Daemon unavailable")
      return
    }

    do {
      let response = try await client.fetchDependencyUpdateBody(
        request: DependencyUpdatesBodyRequest(pullRequestID: id)
      )
      dependencyUpdateBodies.store(
        pullRequestID: response.pullRequestID,
        body: response.body,
        prUpdatedAt: response.prUpdatedAt,
        fetchedAt: response.fetchedAt
      )
      dependencyUpdateBodyState[id] = .loaded(response.body)
    } catch {
      dependencyUpdateBodyState[id] = .failed(error.localizedDescription)
    }
  }
}
