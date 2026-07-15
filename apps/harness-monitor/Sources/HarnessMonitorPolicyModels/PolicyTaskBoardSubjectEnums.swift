/// Task-board priority carried by a policy subject.
///
/// This target cannot depend on `HarnessMonitorKit`, which owns the Monitor's
/// richer task-board models, so the policy wire layer keeps its own matching
/// wire enum.
public enum TaskBoardPriority: String, Codable, Equatable, Sendable {
  case low
  case medium
  case high
  case critical
}

/// Task-board agent mode carried by a policy subject.
public enum TaskBoardAgentMode: String, Codable, Equatable, Sendable {
  case headless
  case interactive
  case planning
  case evaluate
}
