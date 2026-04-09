import HarnessMonitorKit

// Accessibility helpers shared by the native sidebar list rows.
func sessionAccessibilityLabel(for session: SessionSummary) -> String {
  [
    session.displayTitle,
    session.projectName,
    session.checkoutDisplayName,
    session.status.title,
    session.sessionId,
  ].joined(separator: ", ")
}
