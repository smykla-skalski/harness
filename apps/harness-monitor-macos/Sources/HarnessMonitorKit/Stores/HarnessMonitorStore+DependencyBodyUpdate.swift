import CryptoKit
import Foundation

/// Outcome of an optimistic PR-body write through the dependency-update store.
public enum DependencyUpdateBodySetOutcome: Equatable, Sendable {
  /// Daemon accepted the new body and the optimistic state is now confirmed.
  case updated
  /// Daemon found the PR body had drifted since the caller's snapshot. The
  /// `dependencyUpdateBodyState` for the PR has been swapped to the daemon's
  /// returned current body.
  case bodyDrifted
  /// Transport, daemon, or unknown outcome. State has been reverted to
  /// `priorBody`. The message is surfaced for a toast.
  case failed(String)
}

extension HarnessMonitorStore {
  /// Post a new PR body to GitHub via the daemon, optimistically swapping
  /// `dependencyUpdateBodyState[id]` to `newBody` immediately.
  ///
  /// `priorBody` is the body the caller observed when constructing
  /// `newBody`; its SHA-256 is sent to the daemon so concurrent edits (a
  /// teammate or Renovate itself) abort the write instead of clobbering.
  ///
  /// On `.updated` the optimistic body is confirmed and written through to
  /// `dependencyUpdateBodies`. On `.bodyDrifted` the daemon's `currentBody`
  /// replaces the optimistic value. On any other error the prior body and
  /// cache entry are restored.
  public func setDependencyUpdateBody(
    pullRequestID id: String,
    newBody: String,
    priorBody: String
  ) async -> DependencyUpdateBodySetOutcome {
    let priorEntry = dependencyUpdateBodies.cached(forPullRequestID: id)
    dependencyUpdateBodyState[id] = .loaded(newBody)
    if let priorEntry {
      dependencyUpdateBodies.store(
        pullRequestID: id,
        body: newBody,
        prUpdatedAt: priorEntry.prUpdatedAt,
        fetchedAt: priorEntry.fetchedAt
      )
    }

    guard let client else {
      revertDependencyUpdateBody(id: id, priorBody: priorBody, priorEntry: priorEntry)
      return .failed("Daemon unavailable")
    }

    do {
      let response = try await client.updateDependencyUpdateBody(
        request: DependencyUpdatesBodyUpdateRequest(
          pullRequestID: id,
          expectedPriorBodySHA256: HarnessMonitorStore.sha256Hex(of: priorBody),
          newBody: newBody
        )
      )
      return applyDependencyUpdateBodyResponse(
        id: id,
        response: response,
        priorBody: priorBody,
        priorEntry: priorEntry
      )
    } catch {
      revertDependencyUpdateBody(id: id, priorBody: priorBody, priorEntry: priorEntry)
      return .failed(error.localizedDescription)
    }
  }

  private func applyDependencyUpdateBodyResponse(
    id: String,
    response: DependencyUpdatesBodyUpdateResponse,
    priorBody: String,
    priorEntry: DependencyUpdateBodyStore.Entry?
  ) -> DependencyUpdateBodySetOutcome {
    switch response.outcome {
    case .updated:
      dependencyUpdateBodies.store(
        pullRequestID: id,
        body: response.currentBody,
        prUpdatedAt: response.prUpdatedAt,
        fetchedAt: response.fetchedAt
      )
      dependencyUpdateBodyState[id] = .loaded(response.currentBody)
      return .updated
    case .bodyDrifted:
      dependencyUpdateBodies.store(
        pullRequestID: id,
        body: response.currentBody,
        prUpdatedAt: response.prUpdatedAt,
        fetchedAt: response.fetchedAt
      )
      dependencyUpdateBodyState[id] = .loaded(response.currentBody)
      return .bodyDrifted
    case .unknown(let raw):
      revertDependencyUpdateBody(id: id, priorBody: priorBody, priorEntry: priorEntry)
      return .failed("Unrecognized daemon outcome \(raw)")
    }
  }

  private func revertDependencyUpdateBody(
    id: String,
    priorBody: String,
    priorEntry: DependencyUpdateBodyStore.Entry?
  ) {
    dependencyUpdateBodyState[id] = .loaded(priorBody)
    if let priorEntry {
      dependencyUpdateBodies.store(
        pullRequestID: id,
        body: priorEntry.body,
        prUpdatedAt: priorEntry.prUpdatedAt,
        fetchedAt: priorEntry.fetchedAt
      )
    }
  }

  static func sha256Hex(of input: String) -> String {
    let digest = SHA256.hash(data: Data(input.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
