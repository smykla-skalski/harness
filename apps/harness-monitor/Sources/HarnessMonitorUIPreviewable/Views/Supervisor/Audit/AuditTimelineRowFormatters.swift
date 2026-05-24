import Foundation

/// Module-scope formatters for the Supervisor audit timeline row. Allocating a
/// `RelativeDateTimeFormatter` or `DateFormatter` in a SwiftUI view body adds
/// non-trivial steady-state churn while the timeline scrolls. Cache once and
/// reuse for every row.
@MainActor let auditTimelineRelativeFormatter: RelativeDateTimeFormatter = {
  let formatter = RelativeDateTimeFormatter()
  formatter.locale = .autoupdatingCurrent
  formatter.unitsStyle = .abbreviated
  return formatter
}()

@MainActor let auditTimelineAbsoluteFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.locale = .autoupdatingCurrent
  formatter.dateStyle = .medium
  formatter.timeStyle = .medium
  return formatter
}()
