import Foundation
import OSLog

/// Shared OSSignposter for the Dependencies > Files perf surface. Use
/// the helpers below to wrap the fetch / decode / render hot paths so
/// Instruments' SwiftUI + Time Profiler templates can name them.
enum DependencyFilesPerf {
  static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "perf/pr-diffs"
  )

  /// Wrap a metadata fetch (one PR's `files_list` round-trip).
  static func recordMetadataFetch<T>(
    pullRequestID: String,
    _ body: () async throws -> T
  ) async rethrows -> T {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(
      "files.metadata.fetch",
      id: id,
      "pr=\(pullRequestID, privacy: .public)"
    )
    defer { signposter.endInterval("files.metadata.fetch", state) }
    return try await body()
  }

  /// Wrap a per-file patch fetch.
  static func recordPatchFetch<T>(
    pullRequestID: String,
    pathCount: Int,
    _ body: () async throws -> T
  ) async rethrows -> T {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(
      "files.patch.fetch",
      id: id,
      "pr=\(pullRequestID, privacy: .public) paths=\(pathCount)"
    )
    defer { signposter.endInterval("files.patch.fetch", state) }
    return try await body()
  }

  /// Wrap whole-patch tokenization.
  static func recordTokenize<T>(
    path: String,
    _ body: () async throws -> T
  ) async rethrows -> T {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(
      "files.tokenize",
      id: id,
      "path=\(path, privacy: .public)"
    )
    defer { signposter.endInterval("files.tokenize", state) }
    return try await body()
  }

  /// Wrap image-decode pipeline. The body is sync because the call site
  /// already runs inside the actor's executor.
  static func recordImageDecode<T>(
    oid: String,
    _ body: () throws -> T
  ) rethrows -> T {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(
      "files.image.decode",
      id: id,
      "oid=\(oid, privacy: .public)"
    )
    defer { signposter.endInterval("files.image.decode", state) }
    return try body()
  }

  /// Render-side helpers. Emit only when the patch is large enough that
  /// the signpost overhead matters less than the render cost itself.
  static var renderSignpostThresholdLines: Int { 500 }
}
