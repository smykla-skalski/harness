import Foundation
import OSLog

/// Shared OSSignposter for the Reviews > Files perf surface. Use
/// the `Interval` helpers below to wrap fetch / decode / render hot
/// paths so Instruments' SwiftUI + Time Profiler templates can name
/// them. The interval-token shape (instead of closure wrapping)
/// sidesteps Sendable/MainActor checks on async bodies that capture
/// store state.
public enum ReviewFilesPerf {
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

  public static func beginPreviewFetch(pullRequestID: String, pathCount: Int) -> Interval {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(
      "files.preview.fetch",
      id: id,
      "pr=\(pullRequestID, privacy: .public) paths=\(pathCount)"
    )
    return Interval(state: state, name: "files.preview.fetch")
  }

  public static func beginPreviewPrewarm(
    pullRequestID: String,
    pathCount: Int,
    visiblePathCount: Int
  ) -> Interval {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(
      "files.preview.prewarm",
      id: id,
      "pr=\(pullRequestID, privacy: .public) paths=\(pathCount) visible=\(visiblePathCount)"
    )
    return Interval(state: state, name: "files.preview.prewarm")
  }

  public static func beginFilesModeEnter(pullRequestID: String) -> Interval {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(
      "files.mode.enter",
      id: id,
      "pr=\(pullRequestID, privacy: .public)"
    )
    return Interval(state: state, name: "files.mode.enter")
  }

  public static func beginSelectedFileFirstRows(path: String) -> Interval {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(
      "files.selected.first_rows",
      id: id,
      "path=\(path, privacy: .public)"
    )
    return Interval(state: state, name: "files.selected.first_rows")
  }

  public static func beginPrewarmCancel(pullRequestID: String) -> Interval {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(
      "files.preview.prewarm.cancel",
      id: id,
      "pr=\(pullRequestID, privacy: .public)"
    )
    return Interval(state: state, name: "files.preview.prewarm.cancel")
  }

  public static func beginPreviewCacheRead(pullRequestID: String, pathCount: Int) -> Interval {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(
      "files.preview.cache.read",
      id: id,
      "pr=\(pullRequestID, privacy: .public) paths=\(pathCount)"
    )
    return Interval(state: state, name: "files.preview.cache.read")
  }

  public static func beginPreviewCacheStore(pullRequestID: String, pathCount: Int) -> Interval {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(
      "files.preview.cache.store",
      id: id,
      "pr=\(pullRequestID, privacy: .public) paths=\(pathCount)"
    )
    return Interval(state: state, name: "files.preview.cache.store")
  }

  public static func beginPatchCacheRead(pullRequestID: String, pathCount: Int) -> Interval {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(
      "files.patch.cache.read",
      id: id,
      "pr=\(pullRequestID, privacy: .public) paths=\(pathCount)"
    )
    return Interval(state: state, name: "files.patch.cache.read")
  }

  public static func beginPatchCacheStore(pullRequestID: String, pathCount: Int) -> Interval {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(
      "files.patch.cache.store",
      id: id,
      "pr=\(pullRequestID, privacy: .public) paths=\(pathCount)"
    )
    return Interval(state: state, name: "files.patch.cache.store")
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

  public static func beginDiffParse(path: String, lineCount: Int) -> Interval {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(
      "files.diff.parse",
      id: id,
      "path=\(path, privacy: .public) lines=\(lineCount)"
    )
    return Interval(state: state, name: "files.diff.parse")
  }

  public static func beginAppKitDraw(rowCount: Int) -> Interval {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(
      "files.diff.draw",
      id: id,
      "rows=\(rowCount)"
    )
    return Interval(state: state, name: "files.diff.draw")
  }

  public static func beginLatencyProof(size: String, lineCount: Int) -> Interval {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(
      "files.diff.latency_proof",
      id: id,
      "size=\(size, privacy: .public) lines=\(lineCount)"
    )
    return Interval(state: state, name: "files.diff.latency_proof")
  }

  public static func beginVisibleHighlight(size: String, rowCount: Int) -> Interval {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(
      "files.diff.visible_highlight",
      id: id,
      "size=\(size, privacy: .public) rows=\(rowCount)"
    )
    return Interval(state: state, name: "files.diff.visible_highlight")
  }

  public static func beginSharedHighlight(
    surface: String,
    language: String,
    byteCount: Int
  ) -> Interval {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(
      "files.shared.highlight",
      id: id,
      "surface=\(surface, privacy: .public) lang=\(language, privacy: .public) bytes=\(byteCount)"
    )
    return Interval(state: state, name: "files.shared.highlight")
  }

  public static func beginSharedRender(
    surface: String,
    language: String,
    spanCount: Int
  ) -> Interval {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(
      "files.shared.render",
      id: id,
      "surface=\(surface, privacy: .public) lang=\(language, privacy: .public) spans=\(spanCount)"
    )
    return Interval(state: state, name: "files.shared.render")
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
