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
    presentation.agentStat.helpText,
    presentation.taskStat.helpText,
    session.sessionId,
  ].joined(separator: ", ")
}
