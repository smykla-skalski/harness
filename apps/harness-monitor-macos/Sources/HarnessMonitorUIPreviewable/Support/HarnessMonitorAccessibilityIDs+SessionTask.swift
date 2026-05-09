extension HarnessMonitorAccessibility {
  public static let sessionTaskCard = "harness.session.task.card"
  public static let sessionTaskNoteField = "harness.session.task.note-field"
  public static let sessionTaskNoteAddButton = "harness.session.task.note-add"
  public static let sessionTaskNotesUnavailable = "harness.session.task.notes-unavailable"

  public static func sessionTaskTab(_ taskID: String) -> String {
    "harness.session.task.tab.\(slug(taskID))"
  }

  public static func sessionTaskSelection(_ taskID: String) -> String {
    "harness.session.task.selection.\(slug(taskID))"
  }
}
