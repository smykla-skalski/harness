extension HarnessMonitorAccessibility {
  public static let workspaceTaskCard = "harness.workspace.task.card"
  public static let workspaceTaskNoteField = "harness.workspace.task.note-field"
  public static let workspaceTaskNoteAddButton = "harness.workspace.task.note-add"
  public static let workspaceTaskNotesUnavailable = "harness.workspace.task.notes-unavailable"

  public static func workspaceTaskTab(_ taskID: String) -> String {
    "harness.workspace.task.tab.\(slug(taskID))"
  }

  public static func workspaceTaskSelection(_ taskID: String) -> String {
    "harness.workspace.task.selection.\(slug(taskID))"
  }
}
