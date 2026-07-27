import Foundation
import HarnessMonitorKit

/// One value a facet can be narrowed to, and how far it reaches.
struct TaskBoardFilterOption: Equatable, Sendable, Identifiable {
  let id: String
  let label: String
  /// How many cards this value would leave, counted with the rest of the
  /// filter applied but this facet's own selection ignored.
  let count: Int
}

/// Every value the board can currently be narrowed to, per facet.
struct TaskBoardFilterInventory: Equatable, Sendable {
  var projects: [TaskBoardFilterOption] = []
  var priorities: [TaskBoardFilterOption] = []
  var tags: [TaskBoardFilterOption] = []
  var sources: [TaskBoardFilterOption] = []

  static let empty = Self()

  var isEmpty: Bool {
    projects.isEmpty && priorities.isEmpty && tags.isEmpty && sources.isEmpty
  }

  func options(for facet: TaskBoardFilterFacet) -> [TaskBoardFilterOption] {
    switch facet {
    case .project:
      projects
    case .priority:
      priorities
    case .tag:
      tags
    case .source:
      sources
    }
  }

  func hasOptions(in facets: [TaskBoardFilterFacet]) -> Bool {
    facets.contains { !options(for: $0).isEmpty }
  }

  /// How one selected value reads once the option it came from is gone: an
  /// active chip has to keep naming its value even after the last card
  /// carrying it leaves the board.
  func label(for valueID: String, in facet: TaskBoardFilterFacet) -> String {
    options(for: facet).first { $0.id == valueID }?.label ?? valueID
  }
}

extension TaskBoardFilterInventory {
  init(fields population: [TaskBoardFilterFields], matcher: TaskBoardFilterMatcher) {
    var accumulator = Accumulator()
    for fields in population {
      accumulator.record(fields, matcher: matcher)
    }
    accumulator.recordSelection(matcher.filters)
    self.init(
      projects: accumulator.projects.orderedByReach(),
      priorities: accumulator.priorities.ordered(by: Self.priorityOrdering.map(\.rawValue)),
      tags: accumulator.tags.orderedByReach(),
      sources: accumulator.sources.ordered(by: TaskBoardFilterSource.allCases.map(\.rawValue))
    )
  }

  private static let priorityOrdering: [TaskBoardPriority] = [.critical, .high, .medium, .low]

  private struct Accumulator {
    var projects = FacetTally()
    var priorities = FacetTally()
    var tags = FacetTally()
    var sources = FacetTally()

    mutating func record(_ fields: TaskBoardFilterFields, matcher: TaskBoardFilterMatcher) {
      // An active search keeps applying while a facet counts itself: a value
      // has to report what it would leave on the board in front of someone,
      // not on the board they would have without their own search.
      func counts(_ facet: TaskBoardFilterFacet) -> Bool {
        matcher.matches(fields, excluding: .facet(facet))
      }

      if let projectKey = fields.projectKey {
        projects.record(
          id: projectKey,
          label: fields.projectLabel ?? projectKey,
          counts: counts(.project)
        )
      }
      if let priority = fields.priority {
        priorities.record(id: priority.rawValue, label: priority.title, counts: counts(.priority))
      }
      // Two spellings of one tag are one tag, so a card carrying both still
      // counts once towards it.
      let tagCounts = counts(.tag)
      var recordedTagKeys: Set<String> = []
      for tag in fields.tags {
        let key = TaskBoardFilterState.tagKey(tag)
        guard !key.isEmpty, recordedTagKeys.insert(key).inserted else {
          continue
        }
        tags.record(
          id: key,
          label: tag.trimmingCharacters(in: .whitespacesAndNewlines),
          counts: tagCounts
        )
      }
      if let source = fields.source {
        sources.record(id: source.rawValue, label: source.label, counts: counts(.source))
      }
    }

    /// A value someone selected stays listed even once nothing carries it, so
    /// the filter that is hiding the board is still there to switch back off.
    mutating func recordSelection(_ filters: TaskBoardFilterState) {
      for projectKey in filters.projects {
        projects.reserve(id: projectKey, label: projectKey)
      }
      for priority in filters.priorities {
        priorities.reserve(id: priority.rawValue, label: priority.title)
      }
      for tag in filters.tags {
        tags.reserve(id: tag, label: tag)
      }
      for source in filters.sources {
        sources.reserve(id: source.rawValue, label: source.label)
      }
    }
  }

  private struct FacetTally {
    private var labelsByID: [String: String] = [:]
    private var countsByID: [String: Int] = [:]

    mutating func record(id: String, label: String, counts: Bool) {
      reserve(id: id, label: label)
      if counts {
        countsByID[id, default: 0] += 1
      }
    }

    mutating func reserve(id: String, label: String) {
      if labelsByID[id] == nil {
        labelsByID[id] = label
      }
      if countsByID[id] == nil {
        countsByID[id] = 0
      }
    }

    /// Fixed-order facets read in the order the board itself uses.
    func ordered(by idOrdering: [String]) -> [TaskBoardFilterOption] {
      idOrdering.compactMap { id in
        countsByID[id].map { count in
          TaskBoardFilterOption(id: id, label: labelsByID[id] ?? id, count: count)
        }
      }
    }

    /// Open-ended facets lead with the values that leave the most behind.
    func orderedByReach() -> [TaskBoardFilterOption] {
      countsByID
        .map { id, count in
          TaskBoardFilterOption(id: id, label: labelsByID[id] ?? id, count: count)
        }
        .sorted { left, right in
          if left.count != right.count {
            return left.count > right.count
          }
          return left.label.localizedStandardCompare(right.label) == .orderedAscending
        }
    }
  }
}
