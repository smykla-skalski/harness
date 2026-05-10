/// User-selectable search scope.
///
/// `.current` defers to the focused route (resolved at search time via
/// `@FocusedValue(\.harnessSessionRouteFocus)`); the four explicit
/// domains override that resolution.
public enum AppSearchScope: String, CaseIterable, Hashable, Identifiable, Sendable {
  case current
  case agents
  case decisions
  case tasks
  case timeline

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .current: "Current"
    case .agents: "Agents"
    case .decisions: "Decisions"
    case .tasks: "Tasks"
    case .timeline: "Timeline"
    }
  }

  /// `nil` when the scope is `.current` (so the host falls back to the
  /// focused route's domain).
  public var explicitDomain: AppSearchDomain? {
    switch self {
    case .current: nil
    case .agents: .agents
    case .decisions: .decisions
    case .tasks: .tasks
    case .timeline: .timeline
    }
  }
}
