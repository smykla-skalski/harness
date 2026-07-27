import Foundation
import HarnessMonitorKit

/// One field the board can be narrowed by.
///
/// Status is deliberately absent: the lanes already are the statuses, so a card
/// hidden by a status filter would only be hidden from the lane that names it.
enum TaskBoardFilterFacet: String, CaseIterable, Identifiable, Sendable {
  case project
  case priority
  case tag
  case source

  var id: String { rawValue }

  /// The facets worth their own control on the board's filter bar.
  static let dedicated: [Self] = [.project, .priority]

  /// The facets that share the general filter popover.
  static let general: [Self] = [.tag, .source]

  var title: String {
    switch self {
    case .project:
      "Project"
    case .priority:
      "Priority"
    case .tag:
      "Tag"
    case .source:
      "Source"
    }
  }

  /// How one selected value of this facet reads on its chip.
  var chipPrefix: String { title }
}

/// Where an item's work came from.
enum TaskBoardFilterSource: String, CaseIterable, Identifiable, Sendable {
  case gitHub = "github"
  case harness

  var id: String { rawValue }

  var label: String {
    switch self {
    case .gitHub:
      "GitHub"
    case .harness:
      "Harness"
    }
  }
}

/// Which items the board shows, as a selection per facet.
///
/// Values inside one facet widen the selection and facets narrow each other, so
/// two priorities plus one project reads as "either priority, in that project".
struct TaskBoardFilterState: Equatable, Sendable {
  /// Project identities, not names, so a renamed project keeps its filter.
  var projects: Set<String> = []
  var priorities: Set<TaskBoardPriority> = []
  /// Canonical tag keys; `tagKey(_:)` is the only way in.
  var tags: Set<String> = []
  var sources: Set<TaskBoardFilterSource> = []

  var isEmpty: Bool {
    projects.isEmpty && priorities.isEmpty && tags.isEmpty && sources.isEmpty
  }

  /// How many individual values are selected, across every facet.
  var activeValueCount: Int {
    activeValueCount(in: TaskBoardFilterFacet.allCases)
  }

  func activeValueCount(in facets: [TaskBoardFilterFacet]) -> Int {
    facets.reduce(0) { total, facet in
      total + valueCount(for: facet)
    }
  }

  var activeFacets: [TaskBoardFilterFacet] {
    TaskBoardFilterFacet.allCases.filter { !isEmpty(facet: $0) }
  }

  func isEmpty(facet: TaskBoardFilterFacet) -> Bool {
    valueCount(for: facet) == 0
  }

  func valueCount(for facet: TaskBoardFilterFacet) -> Int {
    switch facet {
    case .project:
      projects.count
    case .priority:
      priorities.count
    case .tag:
      tags.count
    case .source:
      sources.count
    }
  }

  mutating func clear() {
    self = .init()
  }

  mutating func clear(_ facet: TaskBoardFilterFacet) {
    switch facet {
    case .project:
      projects = []
    case .priority:
      priorities = []
    case .tag:
      tags = []
    case .source:
      sources = []
    }
  }

  func removing(_ facet: TaskBoardFilterFacet) -> Self {
    var copy = self
    copy.clear(facet)
    return copy
  }

  mutating func toggleProject(_ projectKey: String) {
    Self.toggleMembership(of: projectKey, in: &projects)
  }

  mutating func togglePriority(_ priority: TaskBoardPriority) {
    Self.toggleMembership(of: priority, in: &priorities)
  }

  mutating func toggleTag(_ tag: String) {
    Self.toggleMembership(of: Self.tagKey(tag), in: &tags)
  }

  mutating func toggleSource(_ source: TaskBoardFilterSource) {
    Self.toggleMembership(of: source, in: &sources)
  }

  /// Reduce one tag to the form a facet compares, which is the form `tags`
  /// holds. A board item keeps its own tags exactly as they were typed, so
  /// `"Backend "` and `"backend"` both select through this one key.
  static func tagKey(_ tag: String) -> String {
    tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  /// Value-by-identifier access, so a control can render every facet the same
  /// way instead of growing a branch per facet.
  func contains(_ valueID: String, in facet: TaskBoardFilterFacet) -> Bool {
    switch facet {
    case .project:
      projects.contains(valueID)
    case .priority:
      TaskBoardPriority(rawValue: valueID).map(priorities.contains) ?? false
    case .tag:
      tags.contains(Self.tagKey(valueID))
    case .source:
      TaskBoardFilterSource(rawValue: valueID).map(sources.contains) ?? false
    }
  }

  mutating func toggle(_ valueID: String, in facet: TaskBoardFilterFacet) {
    switch facet {
    case .project:
      toggleProject(valueID)
    case .priority:
      if let priority = TaskBoardPriority(rawValue: valueID) {
        togglePriority(priority)
      }
    case .tag:
      toggleTag(valueID)
    case .source:
      if let source = TaskBoardFilterSource(rawValue: valueID) {
        toggleSource(source)
      }
    }
  }

  mutating func remove(_ valueID: String, from facet: TaskBoardFilterFacet) {
    guard contains(valueID, in: facet) else {
      return
    }
    toggle(valueID, in: facet)
  }

  private static func toggleMembership<Value: Hashable>(
    of value: Value,
    in set: inout Set<Value>
  ) {
    if set.contains(value) {
      set.remove(value)
    } else {
      set.insert(value)
    }
  }
}
