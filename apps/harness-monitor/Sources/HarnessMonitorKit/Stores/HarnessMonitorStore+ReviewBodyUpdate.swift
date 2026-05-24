import CryptoKit
import Foundation

/// Outcome of an optimistic PR-body write through the dependency-update store.
public enum ReviewBodySetOutcome: Equatable, Sendable {
  /// Daemon accepted the new body and the optimistic state is now confirmed.
  case updated
  /// Daemon found the PR body had drifted since the caller's snapshot. The
  /// `reviewBodyState` for the PR has been swapped to the daemon's
  /// returned current body.
  case bodyDrifted
  /// Transport, daemon, or unknown outcome. State has been reverted to
  /// `priorBody`. The message is surfaced for a toast.
  case failed(String)
}

extension HarnessMonitorStore {
  /// Post a new PR body to GitHub via the daemon, optimistically swapping
  /// `reviewBodyState[id]` to `newBody` immediately.
  ///
  /// `priorBody` is the body the caller observed when constructing
  /// `newBody`; its SHA-256 is sent to the daemon so concurrent edits (a
  /// teammate or Renovate itself) abort the write instead of clobbering.
  ///
  /// On `.updated` the optimistic body is confirmed and written through to
  /// `reviewBodies`. On `.bodyDrifted` the daemon's `currentBody`
  /// replaces the optimistic value. On any other error the prior body and
  /// cache entry are restored.
  public func setReviewBody(
    pullRequestID id: String,
    newBody: String,
    priorBody: String
  ) async -> ReviewBodySetOutcome {
    let priorEntry = reviewBodies.cached(forPullRequestID: id)
    reviewBodyState[id] = .loaded(newBody)
    if let priorEntry {
      reviewBodies.store(
        pullRequestID: id,
        body: newBody,
        prUpdatedAt: priorEntry.prUpdatedAt,
        fetchedAt: priorEntry.fetchedAt
      )
    }

    guard let client else {
      revertReviewBody(id: id, priorBody: priorBody, priorEntry: priorEntry)
      return .failed("Daemon unavailable")
    }

    do {
      let response = try await client.updateReviewBody(
        request: ReviewsBodyUpdateRequest(
          pullRequestID: id,
          expectedPriorBodySHA256: HarnessMonitorStore.sha256Hex(of: priorBody),
          newBody: newBody
        )
      )
      return applyReviewBodyResponse(
        id: id,
        response: response,
        priorBody: priorBody,
        priorEntry: priorEntry
      )
    } catch {
      revertReviewBody(id: id, priorBody: priorBody, priorEntry: priorEntry)
      return .failed(error.localizedDescription)
    }
  }

  private func applyReviewBodyResponse(
    id: String,
    response: ReviewsBodyUpdateResponse,
    priorBody: String,
    priorEntry: ReviewBodyStore.Entry?
  ) -> ReviewBodySetOutcome {
    switch response.outcome {
    case .updated:
      reviewBodies.store(
        pullRequestID: id,
        body: response.currentBody,
        prUpdatedAt: response.prUpdatedAt,
        fetchedAt: response.fetchedAt
      )
      reviewBodyState[id] = .loaded(response.currentBody)
      return .updated
    case .bodyDrifted:
      reviewBodies.store(
        pullRequestID: id,
        body: response.currentBody,
        prUpdatedAt: response.prUpdatedAt,
        fetchedAt: response.fetchedAt
      )
      reviewBodyState[id] = .loaded(response.currentBody)
      return .bodyDrifted
    case .unknown(let raw):
      revertReviewBody(id: id, priorBody: priorBody, priorEntry: priorEntry)
      return .failed("Unrecognized daemon outcome \(raw)")
    }
  }

  private func revertReviewBody(
    id: String,
    priorBody: String,
    priorEntry: ReviewBodyStore.Entry?
  ) {
    reviewBodyState[id] = .loaded(priorBody)
    if let priorEntry {
      reviewBodies.store(
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
