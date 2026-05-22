import Foundation
import OSLog

/// Shared OSSignposter for the Reviews > PR-Timeline perf surface.
/// Mirrors `ReviewFilesPerf` (commit `252228513`): the interval-token
/// shape — `Interval` is returned by `begin*()` and passed back to
/// `end(_:)` — avoids closure-wrapping callsites that capture
/// `@MainActor`-isolated store state and would otherwise fail the Swift
/// 6 Sendable / actor-isolation checks at `Task.detached` boundaries.
///
/// **Callsite contract:** every `begin*()` MUST be paired with
/// `defer { ReviewTimelinePerf.end(interval) }` in the same scope.
/// Without the defer, async cancellation leaves the interval unclosed
/// and the Instruments / audit aggregations under-count the work as
/// unterminated spans — `--top` reports become misleading.
public enum ReviewTimelinePerf {
  public static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "perf/pr-timeline"
  )

  /// POD value type: `state` is an `OSSignpostIntervalState` (a UInt64
  /// wrapper), `name` is a `StaticString`. Both are `Sendable` so the
  /// type crosses `Task.detached` boundaries cheaply (copy, not retain).
  public struct Interval: Sendable {
    public let state: OSSignpostIntervalState
    public let name: StaticString
  }

  /// Begin a daemon-fetch interval covering one
  /// `client.fetchReviewTimeline(request:)` round trip. The
  /// `direction` tag distinguishes initial vs load-older fetches in the
  /// trace.
  public static func beginDaemonFetch(
    pullRequestID: String,
    direction: String
  ) -> Interval {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(
      "timeline.daemon.fetch",
      id: id,
      "pr=\(pullRequestID, privacy: .public) dir=\(direction, privacy: .public)"
    )
    return Interval(state: state, name: "timeline.daemon.fetch")
  }

  /// Begin a node-build interval covering the off-main
  /// `ReviewPullRequestTimelineNodeBuilder().buildNodes(...)` call.
  /// The `entries` / `hiddenKinds` counts give post-hoc sizing context
  /// in Instruments without leaking PR-specific PII.
  public static func beginNodeBuild(entries: Int, hiddenKinds: Int) -> Interval {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(
      "timeline.nodes.build",
      id: id,
      "entries=\(entries) hidden=\(hiddenKinds)"
    )
    return Interval(state: state, name: "timeline.nodes.build")
  }

  /// Begin a presentation-rebuild interval covering the synchronous
  /// `SessionTimelineRow.rows(for:configuration:)` that turns built
  /// nodes into rendered rows (day-divider math + formatter resolves).
  public static func beginPresentationRebuild(nodes: Int) -> Interval {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(
      "timeline.presentation.rebuild",
      id: id,
      "nodes=\(nodes)"
    )
    return Interval(state: state, name: "timeline.presentation.rebuild")
  }

  /// Begin an optimistic-insert interval covering the synthetic
  /// `IssueComment` append that happens BEFORE the daemon comment-post
  /// round trip resolves. Lets us measure the latency the user
  /// perceives between "Send" and "comment visible".
  public static func beginOptimisticInsert(pullRequestID: String) -> Interval {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(
      "timeline.optimistic.insert",
      id: id,
      "pr=\(pullRequestID, privacy: .public)"
    )
    return Interval(state: state, name: "timeline.optimistic.insert")
  }

  /// Close a previously-begun interval. Idempotent only in the sense
  /// that `OSSignposter.endInterval` is forgiving — but ALWAYS pair
  /// with `defer { … end(interval) }` to make cancellation safe.
  public static func end(_ interval: Interval) {
    signposter.endInterval(interval.name, interval.state)
  }
}
