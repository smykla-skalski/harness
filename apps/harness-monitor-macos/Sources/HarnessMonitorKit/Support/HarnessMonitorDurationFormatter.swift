import Foundation

/// Format a duration in seconds as a compact human-readable string.
///
/// Rules:
/// - `0` -> `"0s"`
/// - `< 60` seconds -> `"<N>s"`
/// - `< 3600` seconds -> `"<N>m"` (round down to whole minutes)
/// - whole hours under a day -> `"<H>h"`
/// - hours under a day with a remainder -> `"<H>h <M>m"`
/// - whole days -> `"<D>d"`
/// - days with a remainder hour -> `"<D>d <H>h"` (minutes are dropped past a day boundary)
///
/// This is the canonical formatter for cache windows, refresh ceilings, and
/// other durations surfaced in Harness Monitor UI.
public func harnessMonitorDuration(_ seconds: UInt64) -> String {
  if seconds < 60 {
    return "\(seconds)s"
  }
  if seconds < 3_600 {
    return "\(seconds / 60)m"
  }
  if seconds < 86_400 {
    let hours = seconds / 3_600
    let minutes = (seconds % 3_600) / 60
    if minutes == 0 {
      return "\(hours)h"
    }
    return "\(hours)h \(minutes)m"
  }
  let days = seconds / 86_400
  let hours = (seconds % 86_400) / 3_600
  if hours == 0 {
    return "\(days)d"
  }
  return "\(days)d \(hours)h"
}
