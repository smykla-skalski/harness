import Foundation

struct TaskBoardWorkingCopyProgressStreams {
  typealias Continuation = AsyncStream<TaskBoardWorkingCopyProgress>.Continuation

  var byRepository: [String: [UUID: Continuation]] = [:]
  var all: [UUID: Continuation] = [:]
}

/// Per-repo subscription surface for the daemon's
/// `task_board_working_copy_progress` WS push event.
///
/// Mirrors the reviews local-clone progress surface: subscribers get an
/// `AsyncStream<TaskBoardWorkingCopyProgress>` and receive every event whose
/// payload's `repo_full_name` matches, with multiple subscribers per repo fanned
/// out through `UUID` keys.
///
/// `bufferingPolicy: .bufferingNewest(1)` bounds back-pressure when the UI is
/// slow to consume. Dropping an intermediate `advanced` event is harmless - each
/// one carries the whole current state rather than a delta - and the terminal
/// event is the last value either way.
extension HarnessMonitorStore {
  public typealias TaskBoardWorkingCopyProgressContinuation =
    AsyncStream<TaskBoardWorkingCopyProgress>.Continuation

  /// Subscribe to progress for a single repository. Drop the returned stream
  /// (or break out of its `for await` loop) to unsubscribe via `onTermination`.
  public func observeWorkingCopyProgress(
    repoFullName: String
  ) -> AsyncStream<TaskBoardWorkingCopyProgress> {
    let key = repoFullName
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let id = UUID()
      addWorkingCopyProgressSubscriber(
        repoFullName: key,
        id: id,
        continuation: continuation
      )
      continuation.onTermination = { [weak self] _ in
        guard let self else { return }
        Task { @MainActor [weak self] in
          self?.removeWorkingCopyProgressSubscriber(repoFullName: key, id: id)
        }
      }
    }
  }

  /// Subscribe to progress for every repository. Both obtain surfaces use this:
  /// a row can start cloning a repo the view had no progress entry for yet, and
  /// a catch-all subscription avoids re-subscribing as the list changes.
  public func observeAllWorkingCopyProgress() -> AsyncStream<TaskBoardWorkingCopyProgress> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let id = UUID()
      addAllWorkingCopyProgressSubscriber(id: id, continuation: continuation)
      continuation.onTermination = { [weak self] _ in
        guard let self else { return }
        Task { @MainActor [weak self] in
          self?.removeAllWorkingCopyProgressSubscriber(id: id)
        }
      }
    }
  }

  /// Dispatch hook called from the streaming layer. Fans out to every subscriber
  /// registered for the event's `repoFullName` and to every catch-all subscriber.
  func applyWorkingCopyProgress(_ progress: TaskBoardWorkingCopyProgress) {
    if let bucket = workingCopyProgressStreams.byRepository[progress.repoFullName] {
      for continuation in bucket.values {
        continuation.yield(progress)
      }
    }
    for continuation in workingCopyProgressStreams.all.values {
      continuation.yield(progress)
    }
  }

  /// Test-only helper to count active subscribers for a repo, so `onTermination`
  /// cleanup can be asserted without poking `@ObservationIgnored` state.
  public func workingCopyProgressSubscriberCount(repoFullName: String) -> Int {
    workingCopyProgressStreams.byRepository[repoFullName]?.count ?? 0
  }

  // MARK: - Subscriber registry

  private func addWorkingCopyProgressSubscriber(
    repoFullName: String,
    id: UUID,
    continuation: TaskBoardWorkingCopyProgressContinuation
  ) {
    var bucket = workingCopyProgressStreams.byRepository[repoFullName] ?? [:]
    bucket[id] = continuation
    workingCopyProgressStreams.byRepository[repoFullName] = bucket
  }

  private func removeWorkingCopyProgressSubscriber(repoFullName: String, id: UUID) {
    guard var bucket = workingCopyProgressStreams.byRepository[repoFullName] else {
      return
    }
    bucket.removeValue(forKey: id)
    if bucket.isEmpty {
      workingCopyProgressStreams.byRepository.removeValue(forKey: repoFullName)
    } else {
      workingCopyProgressStreams.byRepository[repoFullName] = bucket
    }
  }

  private func addAllWorkingCopyProgressSubscriber(
    id: UUID,
    continuation: TaskBoardWorkingCopyProgressContinuation
  ) {
    workingCopyProgressStreams.all[id] = continuation
  }

  private func removeAllWorkingCopyProgressSubscriber(id: UUID) {
    workingCopyProgressStreams.all.removeValue(forKey: id)
  }
}
