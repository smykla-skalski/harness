import Foundation

/// Per-repo subscription surface for the daemon's
/// `dependency_updates_local_clone_progress` WS push event.
///
/// Subscribers obtain an `AsyncStream<DependencyUpdateLocalCloneProgress>`
/// for a given repo full-name and receive every event whose payload's
/// `repo_full_name` matches. Multiple subscribers per repo are supported;
/// each gets the same value via a fan-out registered through `UUID` keys.
///
/// `bufferingPolicy: .bufferingNewest(1)` keeps back-pressure bounded
/// when the UI thread is slow to consume - we only ever care about the
/// most recent state for a "Cloning..." badge.
extension HarnessMonitorStore {
  public typealias DependencyLocalCloneProgressContinuation =
    AsyncStream<DependencyUpdateLocalCloneProgress>.Continuation

  /// Subscribe to progress events for a single repository. Drop the
  /// returned stream (or break out of its `for await` loop) to
  /// automatically unsubscribe via the stream's `onTermination` hook.
  public func observeLocalCloneProgress(
    repoFullName: String
  ) -> AsyncStream<DependencyUpdateLocalCloneProgress> {
    let key = repoFullName
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let id = UUID()
      addLocalCloneProgressSubscriber(
        repoFullName: key,
        id: id,
        continuation: continuation
      )
      continuation.onTermination = { [weak self] _ in
        guard let self else { return }
        Task { @MainActor [weak self] in
          self?.removeLocalCloneProgressSubscriber(repoFullName: key, id: id)
        }
      }
    }
  }

  /// Dispatch hook called from the streaming layer. Fans out to every
  /// subscriber registered for the event's `repoFullName` and yields the
  /// payload. No-op when no subscribers are registered for that repo.
  func applyLocalCloneProgress(_ progress: DependencyUpdateLocalCloneProgress) {
    let bucket = dependencyLocalCloneProgressContinuations[progress.repoFullName]
    guard let bucket, !bucket.isEmpty else { return }
    for continuation in bucket.values {
      continuation.yield(progress)
    }
  }

  /// Test-only helper to count active subscribers for a repo. Lets
  /// `onTermination` cleanup be asserted from XCTest without poking
  /// `@ObservationIgnored` state directly.
  public func dependencyLocalCloneProgressSubscriberCount(
    repoFullName: String
  ) -> Int {
    dependencyLocalCloneProgressContinuations[repoFullName]?.count ?? 0
  }

  // MARK: - Subscriber registry

  private func addLocalCloneProgressSubscriber(
    repoFullName: String,
    id: UUID,
    continuation: DependencyLocalCloneProgressContinuation
  ) {
    var bucket = dependencyLocalCloneProgressContinuations[repoFullName] ?? [:]
    bucket[id] = continuation
    dependencyLocalCloneProgressContinuations[repoFullName] = bucket
  }

  private func removeLocalCloneProgressSubscriber(
    repoFullName: String,
    id: UUID
  ) {
    guard var bucket = dependencyLocalCloneProgressContinuations[repoFullName] else { return }
    bucket.removeValue(forKey: id)
    if bucket.isEmpty {
      dependencyLocalCloneProgressContinuations.removeValue(forKey: repoFullName)
    } else {
      dependencyLocalCloneProgressContinuations[repoFullName] = bucket
    }
  }
}
