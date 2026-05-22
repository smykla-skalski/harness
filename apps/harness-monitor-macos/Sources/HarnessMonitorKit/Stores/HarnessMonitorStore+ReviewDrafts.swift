import Foundation

extension HarnessMonitorStore {
  fileprivate static let draftDebounceDuration: Duration = .milliseconds(500)

  /// Schedules a debounced write of `draft` to UserDefaults keyed by
  /// `pullRequestID`. Repeated calls within the 500ms window cancel
  /// the in-flight write so UserDefaults only sees the latest value
  /// per typing pause — per plan §6.3.
  ///
  /// Passing an empty / whitespace-only draft removes the key
  /// entirely so abandoned composer state doesn't accumulate.
  public func scheduleReviewDraftWrite(
    _ pullRequestID: String,
    draft: String
  ) {
    reviewDraftWriteTasks[pullRequestID]?.cancel()
    let key = Self.reviewDraftKey(for: pullRequestID)
    reviewDraftWriteTasks[pullRequestID] = Task { @MainActor in
      try? await Task.sleep(for: HarnessMonitorStore.draftDebounceDuration)
      guard !Task.isCancelled else { return }
      let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        UserDefaults.standard.removeObject(forKey: key)
      } else {
        UserDefaults.standard.set(draft, forKey: key)
      }
    }
  }

  /// Reads the persisted draft for `pullRequestID`. Returns `""` when
  /// no draft is on disk so the composer can seed `@State` directly.
  public func reviewCommentDraft(for pullRequestID: String) -> String {
    let key = Self.reviewDraftKey(for: pullRequestID)
    return UserDefaults.standard.string(forKey: key) ?? ""
  }

  static func reviewDraftKey(for pullRequestID: String) -> String {
    "dependency.composer.draft.\(pullRequestID)"
  }
}
