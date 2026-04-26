extension HarnessMonitorAccessibility {
  public static let agentsTaskCard = "harness.agents.task.card"
  public static let agentsTaskNoteField = "harness.agents.task.note-field"
  public static let agentsTaskNoteAddButton = "harness.agents.task.note-add"
  public static let agentsTaskNotesUnavailable = "harness.agents.task.notes-unavailable"

  public static func agentsTaskTab(_ taskID: String) -> String {
    "harness.agents.task.tab.\(slug(taskID))"
  }

  public static func agentsTaskSelection(_ taskID: String) -> String {
    "harness.agents.task.selection.\(slug(taskID))"
  }
}
