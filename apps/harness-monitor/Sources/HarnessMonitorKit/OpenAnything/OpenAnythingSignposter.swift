import Foundation
import os

/// OSSignposter wrapper for the Open Anything subsystem.
///
/// Subsystem matches the project-wide perf convention: io.harnessmonitor.
/// Category is `perf` so the signposts align with the existing perf-scenario
/// pipeline and Instruments traces.
public enum OpenAnythingSignposter {
  public static let shared = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "perf"
  )

  /// Named intervals used across the Open Anything subsystem. Keep the names
  /// stable because the perf JSON references them.
  public enum Interval {
    public static let present: StaticString = "openAnything.present"
    public static let search: StaticString = "openAnything.search"
    public static let execute: StaticString = "openAnything.execute"
    public static let corpusRebuild: StaticString = "openAnything.corpus_rebuild"
  }
}
