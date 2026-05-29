import HarnessMonitorKit

enum DashboardPolicyCanvasSwitchMutation {
  case activate(TaskBoardPolicyCanvasSummary)
  case create(title: String)
  case duplicate(source: TaskBoardPolicyCanvasSummary, title: String)

  var confirmationMessage: String {
    switch self {
    case .activate(let canvas):
      "Save or discard the current changes before opening “\(canvas.title)”."
    case .create(let title):
      "Save or discard the current changes before creating and opening “\(title)”."
    case .duplicate(let source, let title):
      "Save or discard the current changes before duplicating “\(source.title)” into “\(title)”."
    }
  }
}

struct DashboardPolicyCanvasDeleteRequest {
  let canvas: TaskBoardPolicyCanvasSummary
  let requiresDirtyResolution: Bool

  var message: String {
    if requiresDirtyResolution {
      return
        "Deleting “\(canvas.title)” will also replace the unsaved edits in the current canvas. "
        + "Save them first or delete without saving."
    }
    return "Delete “\(canvas.title)”? This cannot be undone."
  }
}
