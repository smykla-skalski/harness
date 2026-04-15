import HarnessMonitorKit

// Accessibility helpers shared by the native sidebar list rows.
func sessionAccessibilityLabel(
  for session: SessionSummary,
  presentation: HarnessMonitorStore.SessionSummaryPresentation
) -> String {
  [
    session.displayTitle,
    session.projectName,
    session.checkoutDisplayName,
    presentation.accessibilityStatusText,
    session.sessionId,
  ].joined(separator: ", ")
}
