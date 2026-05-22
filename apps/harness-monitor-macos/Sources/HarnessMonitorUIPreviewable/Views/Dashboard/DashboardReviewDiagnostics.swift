import HarnessMonitorKit

func dashboardReviewFixCIBody(
  for item: ReviewItem,
  activity: DashboardReviewActivitySnapshot
) -> String {
  let failedChecks = dashboardReviewFailedCheckDiagnostics(for: item)
  let labels = item.labels.isEmpty ? "none" : item.labels.sorted().joined(separator: ", ")
  let failedCheckSection =
    failedChecks.isEmpty
    ? "Failed checks: none reported"
    : "Failed checks:\n" + failedChecks.joined(separator: "\n")
  let lastActionSection =
    activity.lastAction.map { entry in
      """
      Recent review action:
      - title: \(entry.title)
      - outcome: \(entry.outcome.diagnosticsLabel)
      - summary: \(entry.summary)
      \(entry.messages.map { "- message: \($0)" }.joined(separator: "\n"))
      """
    } ?? "Recent review action: none in current Monitor session"

  return """
    Investigate and restore mergeability for \(item.repository)#\(item.number).

    Pull request: \(item.url)
    Repository: \(item.repository)
    Number: \(item.number)
    Author: @\(item.authorLogin)
    Head SHA: \(item.headSha)
    Mergeable: \(item.mergeable.rawValue)
    Review status: \(item.reviewStatus.label)
    Check status: \(item.checkStatus.label)
    Labels: \(labels)
    Missing check run links: \(activity.missingCheckRunURLCount)/\(activity.totalCheckCount)

    \(failedCheckSection)

    \(lastActionSection)
    """
}

func dashboardReviewFailedCheckDiagnostics(for item: ReviewItem) -> [String] {
  item.checks.filter(\.requiresAttention).map { check in
    let link = check.detailsWebURL.map { " \($0.absoluteString)" } ?? " no check URL"
    return "- \(check.name): \(check.statusLabel)\(link)"
  }
}
