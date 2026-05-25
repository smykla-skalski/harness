import Foundation
import HarnessMonitorCore
import HarnessMonitorKit

extension HarnessMonitorClientMobileMirrorSnapshotSource {
  func needsReviewAttention(_ review: ReviewItem) -> Bool {
    review.reviewStatus == .reviewRequired
      || review.policyBlocked
      || review.checkStatus == .failure
  }

  func reviewPayload(_ review: ReviewItem) -> [String: String] {
    [
      "repository": review.repository,
      "number": String(review.number),
      "headSha": review.headSha,
    ]
  }

  func isActive(_ agent: ManagedAgentSnapshot) -> Bool {
    switch agent {
    case .terminal(let snapshot):
      snapshot.status.isActive
    case .codex(let snapshot):
      snapshot.status.isActive
    case .acp(let snapshot):
      snapshot.status == .active
    }
  }

  func isBlocked(_ agent: ManagedAgentSnapshot) -> Bool {
    switch agent {
    case .terminal(let snapshot):
      snapshot.status == .failed
    case .codex(let snapshot):
      snapshot.status == .waitingApproval || !snapshot.pendingApprovals.isEmpty
    case .acp(let snapshot):
      snapshot.pendingPermissions > 0 || snapshot.status == .awaitingReview
    }
  }

  func taskBoardSeverity(_ item: TaskBoardItem) -> MobileAttentionSeverity {
    switch item.priority {
    case .critical:
      .critical
    case .high, .medium, .low:
      .warning
    }
  }

  func taskBoardSubtitle(_ item: TaskBoardItem) -> String {
    let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
    let subject = body.isEmpty ? item.title : body
    let trimmedSubject =
      subject.count > 140
      ? "\(subject.prefix(137))..."
      : subject
    return "\(item.title) - \(item.status.title) - \(item.priority.title). \(trimmedSubject)"
  }

  func parseDate(_ value: String?, fallback: Date) -> Date {
    guard let value, !value.isEmpty else {
      return fallback
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) {
      return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value) ?? fallback
  }

  func redacted(_ value: String) -> String {
    secretRedactor.redact(value)
  }

  func redacted(_ value: String?) -> String? {
    value.map { redacted($0) }
  }

  func redactedSnapshot(_ snapshot: MobileMirrorSnapshot) -> MobileMirrorSnapshot {
    var snapshot = snapshot
    snapshot.stations = snapshot.stations.map(redactedStation)
    snapshot.attention = snapshot.attention.map(redactedAttention)
    snapshot.sessions = snapshot.sessions.map(redactedSession)
    snapshot.reviews = snapshot.reviews.map(redactedReview)
    snapshot.taskBoardItems = snapshot.taskBoardItems.map(redactedTaskBoardItem)
    snapshot.commands = snapshot.commands.map {
      $0.redactingMobileMirrorSecrets(using: secretRedactor)
    }
    snapshot.stations = stationsWithDerivedNeedsYouCounts(in: snapshot)
    return snapshot
  }

  func stationsWithDerivedNeedsYouCounts(
    in snapshot: MobileMirrorSnapshot
  ) -> [MobileStationSummary] {
    let countsByStation = Dictionary(
      grouping: snapshot.cockpitAttention.filter(\.needsUserAction),
      by: \.stationID
    ).mapValues(\.count)
    return snapshot.stations.map { station in
      var station = station
      station.needsYouCount = countsByStation[station.id] ?? 0
      return station
    }
  }

  func redactedStation(_ station: MobileStationSummary) -> MobileStationSummary {
    var station = station
    station.displayName = redacted(station.displayName)
    return station
  }

  func redactedAttention(_ item: MobileAttentionItem) -> MobileAttentionItem {
    var item = item
    item.title = redacted(item.title)
    item.subtitle = redacted(item.subtitle)
    return item
  }

  func redactedSession(_ session: MobileSessionSummary) -> MobileSessionSummary {
    var session = session
    session.projectName = redacted(session.projectName)
    session.title = redacted(session.title)
    session.branch = redacted(session.branch)
    session.summary = redacted(session.summary)
    session.agents = session.agents.map(redactedAgent)
    return session
  }

  func redactedAgent(_ agent: MobileAgentSummary) -> MobileAgentSummary {
    var agent = agent
    agent.displayName = redacted(agent.displayName)
    agent.role = redacted(agent.role)
    agent.summary = redacted(agent.summary)
    return agent
  }

  func redactedReview(_ review: MobileReviewSummary) -> MobileReviewSummary {
    var review = review
    review.url = redacted(review.url)
    review.title = redacted(review.title)
    review.author = redacted(review.author)
    review.labels = review.labels.map(redacted)
    review.checks = review.checks.map(redactedReviewCheck)
    review.files = review.files.map(redactedReviewFile)
    review.activity = review.activity.map(redactedReviewActivity)
    review.requiredFailedCheckNames = review.requiredFailedCheckNames.map(redacted)
    return review
  }

  func redactedReviewCheck(
    _ check: MobileReviewCheckSnippet
  ) -> MobileReviewCheckSnippet {
    var check = check
    check.id = redacted(check.id)
    check.name = redacted(check.name)
    check.detailsURL = redacted(check.detailsURL)
    return check
  }

  func redactedReviewFile(
    _ file: MobileReviewFileSnippet
  ) -> MobileReviewFileSnippet {
    var file = file
    file.id = redacted(file.id)
    file.path = redacted(file.path)
    return file
  }

  func redactedReviewActivity(
    _ activity: MobileReviewActivitySnippet
  ) -> MobileReviewActivitySnippet {
    var activity = activity
    activity.actor = redacted(activity.actor)
    activity.summary = redacted(activity.summary)
    return activity
  }

  func redactedTaskBoardItem(
    _ item: MobileTaskBoardSummary
  ) -> MobileTaskBoardSummary {
    var item = item
    item.title = redacted(item.title)
    item.bodyPreview = redacted(item.bodyPreview)
    item.tags = item.tags.map(redacted)
    item.projectID = redacted(item.projectID)
    return item
  }
}
