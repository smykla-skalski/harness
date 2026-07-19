import Foundation
import HarnessMonitorKit

/// Precomputed, per-card presentation data assembled by `TaskBoardOverviewPresentationWorker`.
/// Deliberately excludes anything derived from `fontScale` or color scheme - those stay
/// environment-driven and get assembled live in leaf views from the fragments/dates below.
struct TaskBoardCardPresentation: Equatable, Sendable {
  let titleFragments: [TaskBoardInlineCodeFragment]
  let titleLeadingText: String?
  let titleDisplayText: String
  let glyph: TaskBoardCardGlyph?
  let updatedAt: Date?
  let repositoryLabelDefault: String?
  let repositoryLabelFullName: String?

  static func forAPIItem(
    _ item: TaskBoardItem,
    projectLabelResolver: TaskBoardProjectLabelResolver
  ) -> TaskBoardCardPresentation {
    let titlePresentation = TaskBoardCardTitlePresentation(item: item)
    let fragments = TaskBoardInlineCodeFormatter.fragments(in: titlePresentation.title)
    let repositoryLabelDefault: String?
    let repositoryLabelFullName: String?
    if let projectID = item.projectId {
      repositoryLabelDefault = projectLabelResolver.label(
        for: projectID,
        alwaysShowFullName: false
      )
      repositoryLabelFullName = projectLabelResolver.label(
        for: projectID,
        alwaysShowFullName: true
      )
    } else {
      repositoryLabelDefault = nil
      repositoryLabelFullName = nil
    }
    return TaskBoardCardPresentation(
      titleFragments: fragments,
      titleLeadingText: titlePresentation.leadingText,
      titleDisplayText: TaskBoardInlineCodeFormatter.displayText(
        for: fragments,
        leadingText: titlePresentation.leadingText
      ),
      glyph: TaskBoardGitHubCardGlyph.resolve(for: item),
      updatedAt: TaskBoardCardDateParsing.parse(item.updatedAt),
      repositoryLabelDefault: repositoryLabelDefault,
      repositoryLabelFullName: repositoryLabelFullName
    )
  }

  static func forInboxItem(_ item: TaskBoardInboxItem) -> TaskBoardCardPresentation {
    let fragments = TaskBoardInlineCodeFormatter.fragments(in: item.task.title)
    return TaskBoardCardPresentation(
      titleFragments: fragments,
      titleLeadingText: nil,
      titleDisplayText: TaskBoardInlineCodeFormatter.displayText(for: fragments),
      glyph: nil,
      updatedAt: TaskBoardCardDateParsing.parse(item.task.updatedAt),
      repositoryLabelDefault: nil,
      repositoryLabelFullName: nil
    )
  }
}

/// Timestamp parsing usable off the main actor: the worker actor can't reach the cached
/// `@MainActor` formatters in `HarnessMonitorFormatters.swift`, so formatters here are allocated
/// fresh per call instead of shared, avoiding cross-thread mutable state.
enum TaskBoardCardDateParsing {
  static func parse(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) {
      return date
    }
    let standard = ISO8601DateFormatter()
    standard.formatOptions = [.withInternetDateTime]
    if let date = standard.date(from: value) {
      return date
    }
    let spaceSeparated = DateFormatter()
    spaceSeparated.locale = Locale(identifier: "en_US_POSIX")
    spaceSeparated.timeZone = TimeZone(secondsFromGMT: 0)
    spaceSeparated.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return spaceSeparated.date(from: value)
  }
}
