import Foundation
import OSLog

/// Shared OSSignposter for the Dependencies > Files perf surface. Use
/// the `Interval` helpers below to wrap fetch / decode / render hot
/// paths so Instruments' SwiftUI + Time Profiler templates can name
/// them. The interval-token shape (instead of closure wrapping)
/// sidesteps Sendable/MainActor checks on async bodies that capture
/// store state.
public enum DependencyFilesPerf {
  public static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "perf/pr-diffs"
  )

  public struct Interval {
    public let state: OSSignpostIntervalState
    public let name: StaticString
  }

  /// Begin a metadata-fetch signpost interval. Call `end(_:)` after the
  /// associated work completes.
  public static func beginMetadataFetch(pullRequestID: String) -> Interval {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(
      "files.metadata.fetch",
      id: id,
      "pr=\(pullRequestID, privacy: .public)"
    )
    return Interval(state: state, name: "files.metadata.fetch")
  }

  public static func beginPatchFetch(pullRequestID: String, pathCount: Int) -> Interval {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(
      "files.patch.fetch",
      id: id,
      "pr=\(pullRequestID, privacy: .public) paths=\(pathCount)"
    )
    return Interval(state: state, name: "files.patch.fetch")
  }

  public static func beginTokenize(path: String) -> Interval {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(
      "files.tokenize",
      id: id,
      "path=\(path, privacy: .public)"
    )
    return Interval(state: state, name: "files.tokenize")
  }

  public static func beginImageDecode(oid: String) -> Interval {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(
      "files.image.decode",
      id: id,
      "oid=\(oid, privacy: .public)"
    )
    return Interval(state: state, name: "files.image.decode")
  }

  public static func end(_ interval: Interval) {
    signposter.endInterval(interval.name, interval.state)
  }

  /// Render-side helpers. Emit only when the patch is large enough that
  /// the signpost overhead matters less than the render cost itself.
  public static var renderSignpostThresholdLines: Int { 500 }
}
