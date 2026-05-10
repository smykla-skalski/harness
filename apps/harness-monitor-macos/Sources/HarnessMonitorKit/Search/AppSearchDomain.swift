import Foundation

/// One of the four searchable corpora indexed by ``AppSearchIndex``.
///
/// `AppSearchDomain` is a pure model identity. It does not carry "current"
/// route resolution; the UI layer maps the active route to a domain via
/// ``HarnessSessionRouteFocus`` and hands the resolved value to the index.
public enum AppSearchDomain: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
  case agents
  case decisions
  case tasks
  case timeline

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .agents:
      "Agents"
    case .decisions:
      "Decisions"
    case .tasks:
      "Tasks"
    case .timeline:
      "Timeline"
    }
  }

  /// SF Symbol used by section headers and individual hit rows.
  /// Kept here so the index can attach symbols without the UI layer
  /// having to map domain to glyph at every render.
  public var systemImage: String {
    switch self {
    case .agents:
      "person.2"
    case .decisions:
      "checkmark.diamond"
    case .tasks:
      "checklist"
    case .timeline:
      "clock.arrow.circlepath"
    }
  }
}
