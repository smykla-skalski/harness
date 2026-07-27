import Foundation
import HarnessMonitorKit

/// The one view of a card the board's filter and search are allowed to read.
///
/// Every card on the board reduces to this before matching, so a live session
/// task and a board item are narrowed by the same rules instead of each lane
/// growing its own. A field left `nil` is a field the card does not carry, and
/// a filter on that field never selects the card.
struct TaskBoardFilterFields: Equatable, Sendable {
  var title: String = ""
  var body: String = ""
  var priority: TaskBoardPriority?
  var projectKey: String?
  var projectLabel: String?
  /// Original spellings; matching canonicalizes them.
  var tags: [String] = []
  var source: TaskBoardFilterSource?

  init(
    title: String = "",
    body: String = "",
    priority: TaskBoardPriority? = nil,
    projectKey: String? = nil,
    projectLabel: String? = nil,
    tags: [String] = [],
    source: TaskBoardFilterSource? = nil
  ) {
    self.title = title
    self.body = body
    self.priority = priority
    self.projectKey = projectKey
    self.projectLabel = projectLabel
    self.tags = tags
    self.source = source
  }

  /// The text a search reads, with the fields kept apart so no term can match
  /// across the seam between the end of one and the start of the next.
  var searchableText: String {
    ([title, body] + tags).joined(separator: "\n")
  }
}

extension TaskBoardFilterFields {
  init(item: TaskBoardItem, projectLabelResolver: TaskBoardProjectLabelResolver) {
    self.init(
      title: item.title,
      body: item.body,
      priority: item.priority,
      projectKey: Self.projectKey(for: item),
      projectLabel: projectLabelResolver.label(for: item, alwaysShowFullName: true),
      tags: item.tags,
      source: item.importedFromProvider == .gitHub ? .gitHub : .harness
    )
  }

  init(inboxItem: TaskBoardInboxItem) {
    self.init(
      title: inboxItem.task.title,
      body: inboxItem.task.context ?? "",
      priority: Self.priority(for: inboxItem.task.severity)
    )
  }

  /// An open decision carries none of the fields a facet reads, so any active
  /// facet excludes it. Its summary is still text on a card, so a search does
  /// reach it.
  init(decision: DecisionPresentationItem) {
    self.init(title: decision.summary)
  }

  /// The identity a project filter selects on: the registered project when the
  /// item names one, else the repository the item carries. Keyed on the stored
  /// identity rather than the label so renaming a project keeps its filter.
  static func projectKey(for item: TaskBoardItem) -> String? {
    if let sourceProjectID = item.sourceProjectId, !sourceProjectID.isEmpty {
      return sourceProjectID
    }
    return item.taskBoardRepositoryIdentity
  }

  private static func priority(for severity: TaskSeverity) -> TaskBoardPriority {
    switch severity {
    case .low:
      .low
    case .medium:
      .medium
    case .high:
      .high
    case .critical:
      .critical
    }
  }
}
