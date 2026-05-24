import Foundation
import HarnessMonitorKit

/// Per-PR @Observable @MainActor row source for the Reviews
/// PR conversation feed. Owns the built `[SessionTimelineRow]` plus the
/// rebuild generation counter, so the row state lives outside the
/// generic `DashboardReviewDetailView<Actions>` and is shared by
/// any presenter that needs the same PR's rendered rows.
///
/// Per `references/performance-patterns.md` §10 "@Observable Dependency
/// Granularity", narrow per-PR observable units let the row consumer
/// re-evaluate its body only when THIS PR's rows change — not when the
/// whole `ReviewTimelineViewModels` dictionary mutates.
///
/// The source is created lazily by
/// `HarnessMonitorStore.dependencyConversationRowSource(for:)` and
/// cached in a non-observed dictionary on the store, so creating one
/// for a newly-visited PR doesn't invalidate readers of other PRs.
///
/// **Rebuild ownership.** `refresh(entries:hiddenKinds:autoCollapseHeavyReviewThreads:configuration:)`
/// is the only writer; it captures all view-side inputs as
/// `Sendable` value types into the `Task.detached` builder so the
/// detached task body never touches `@MainActor`-isolated state. The
/// generation counter guards against out-of-order completions when
/// `refresh` is invoked multiple times during a single typing
/// transition.
@MainActor
@Observable
final class ReviewConversationRowSource {
  private(set) var rows: [SessionTimelineRow] = []
  @ObservationIgnored private var generation: UInt64 = 0

  init() {}

  /// Replaces `rows` with the result of building from `entries`,
  /// `hiddenKinds`, etc. Builds nodes off-main in a detached task and
  /// commits the resulting rows back to the @MainActor source.
  ///
  /// Concurrent calls drop earlier results: each invocation bumps the
  /// generation counter, captures a snapshot, and only commits if the
  /// snapshot still matches when the build returns.
  func refresh(
    entries: [ReviewTimelineEntry],
    hiddenKinds: Set<ReviewTimelineKind>,
    autoCollapseHeavyReviewThreads: Bool,
    configuration: HarnessMonitorDateTimeConfiguration
  ) async {
    generation &+= 1
    let snapshot = generation
    let buildInterval = ReviewTimelinePerf.beginNodeBuild(
      entries: entries.count,
      hiddenKinds: hiddenKinds.count
    )
    let nodes = await Task.detached(priority: .userInitiated) {
      () -> [SessionTimelineNode] in
      ReviewPullRequestTimelineNodeBuilder().buildNodes(
        for: entries,
        pullRequestID: "",
        hiddenKinds: hiddenKinds,
        autoCollapseHeavyReviewThreads: autoCollapseHeavyReviewThreads,
        configuration: configuration
      )
    }.value
    ReviewTimelinePerf.end(buildInterval)
    guard !Task.isCancelled, generation == snapshot else { return }
    let presentationInterval =
      ReviewTimelinePerf.beginPresentationRebuild(nodes: nodes.count)
    defer { ReviewTimelinePerf.end(presentationInterval) }
    rows = SessionTimelineRow.rows(for: nodes, configuration: configuration)
  }

  /// Clear the rebuilt rows; called when the consumer's preferences
  /// hide the timeline entirely so stale rows don't linger across
  /// re-opens.
  func clear() {
    rows = []
  }
}
