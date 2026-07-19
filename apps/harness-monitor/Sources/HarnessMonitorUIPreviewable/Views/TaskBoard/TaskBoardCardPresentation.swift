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
    projectLabelResolver: TaskBoardProjectLabelResolver,
    dateParser: TaskBoardCardDateParser
  ) -> Self {
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
    return Self(
      titleFragments: fragments,
      titleLeadingText: titlePresentation.leadingText,
      titleDisplayText: TaskBoardInlineCodeFormatter.displayText(
        for: fragments,
        leadingText: titlePresentation.leadingText
      ),
      glyph: TaskBoardGitHubCardGlyph.resolve(for: item),
      updatedAt: dateParser.parse(item.updatedAt),
      repositoryLabelDefault: repositoryLabelDefault,
      repositoryLabelFullName: repositoryLabelFullName
    )
  }

  static func forInboxItem(
    _ item: TaskBoardInboxItem,
    dateParser: TaskBoardCardDateParser
  ) -> Self {
    let fragments = TaskBoardInlineCodeFormatter.fragments(in: item.task.title)
    return Self(
      titleFragments: fragments,
      titleLeadingText: nil,
      titleDisplayText: TaskBoardInlineCodeFormatter.displayText(for: fragments),
      glyph: nil,
      updatedAt: dateParser.parse(item.task.updatedAt),
      repositoryLabelDefault: nil,
      repositoryLabelFullName: nil
    )
  }
}

/// Timestamp parsing usable off the main actor: the worker actor can't reach the cached
/// `@MainActor` formatters in `HarnessMonitorFormatters.swift`. `TaskBoardCardDateParser` holds
/// the 3 formatters as instance state so the presentation worker allocates them once per snapshot
/// compute (not once per card); `TaskBoardCardDateParsing.parse(_:)` is the fallback used by the
/// `TaskBoardLaneViews` row path when `cardPresentation` is nil (dictionary miss, previews,
/// tests) - it caches one `@MainActor` instance instead of allocating per call, since that
/// fallback is still reachable during body evaluation.
struct TaskBoardCardDateParser {
  private let fractional: ISO8601DateFormatter
  private let standard: ISO8601DateFormatter
  private let spaceSeparated: DateFormatter

  init() {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    self.fractional = fractional

    let standard = ISO8601DateFormatter()
    standard.formatOptions = [.withInternetDateTime]
    self.standard = standard

    let spaceSeparated = DateFormatter()
    spaceSeparated.locale = Locale(identifier: "en_US_POSIX")
    spaceSeparated.timeZone = TimeZone(secondsFromGMT: 0)
    spaceSeparated.dateFormat = "yyyy-MM-dd HH:mm:ss"
    self.spaceSeparated = spaceSeparated
  }

  func parse(_ value: String) -> Date? {
    fractional.date(from: value)
      ?? standard.date(from: value)
      ?? spaceSeparated.date(from: value)
  }
}

enum TaskBoardCardDateParsing {
  @MainActor private static let parser = TaskBoardCardDateParser()

  @MainActor
  static func parse(_ value: String) -> Date? {
    parser.parse(value)
  }
}
