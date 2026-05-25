import Foundation
import HarnessMonitorCore
import HarnessMonitorKit

extension HarnessMonitorClientMobileMirrorSnapshotSource {
  func sessionTaskSeverity(_ task: WorkItem) -> MobileAttentionSeverity {
    switch task.severity {
    case .critical:
      .critical
    case .high, .medium, .low:
      .warning
    }
  }

  func sessionTaskSubtitle(session: SessionSummary, task: WorkItem) -> String {
    let detail =
      task.blockedReason?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? task.context?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? ""
    let summary = detail.isEmpty ? task.title : detail
    let trimmedSummary =
      summary.count > 140
      ? "\(summary.prefix(137))..."
      : summary
    return "\(session.displayTitle) - \(task.title) - \(task.severity.title). \(trimmedSummary)"
  }

  func mobileSession(
    _ session: SessionSummary,
    agents: [ManagedAgentSnapshot],
    now: Date
  ) -> MobileSessionSummary {
    MobileSessionSummary(
      id: session.sessionId,
      stationID: stationID,
      projectName: redacted(session.projectName),
      title: redacted(session.displayTitle),
      branch: redacted(session.branchRef),
      status: session.status.title,
      activeAgentCount: agents.count(where: isActive),
      blockedAgentCount: agents.count(where: isBlocked),
      lastActivityAt: parseDate(session.lastActivityAt ?? session.updatedAt, fallback: now),
      summary: redacted(session.context),
      agents: agents.map { mobileAgent($0, now: now) }
        .sorted { lhs, rhs in
          if lhs.isBlocked != rhs.isBlocked {
            return lhs.isBlocked && !rhs.isBlocked
          }
          if lhs.isActive != rhs.isActive {
            return lhs.isActive && !rhs.isActive
          }
          return lhs.lastActivityAt > rhs.lastActivityAt
        }
    )
  }

  func mobileAgent(
    _ agent: ManagedAgentSnapshot,
    now: Date
  ) -> MobileAgentSummary {
    switch agent {
    case .terminal(let snapshot):
      return MobileAgentSummary(
        id: snapshot.managedAgentID,
        stationID: stationID,
        sessionID: snapshot.sessionId,
        displayName: redacted("\(snapshot.runtime) \(snapshot.agentId)"),
        family: .terminal,
        status: snapshot.status.title,
        role: nil,
        isActive: snapshot.status.isActive,
        isBlocked: snapshot.status == .failed,
        lastActivityAt: parseDate(snapshot.updatedAt, fallback: now),
        summary: redacted(snapshot.error ?? snapshot.projectDir)
      )
    case .codex(let snapshot):
      let pendingApprovals = snapshot.pendingApprovals.count
      return MobileAgentSummary(
        id: snapshot.managedAgentID,
        stationID: stationID,
        sessionID: snapshot.sessionId,
        displayName: redacted(snapshot.displayName ?? snapshot.runId),
        family: .codex,
        status: snapshot.status.title,
        role: nil,
        isActive: snapshot.status.isActive,
        isBlocked: snapshot.status == .waitingApproval || pendingApprovals > 0
          || snapshot.status == .failed,
        pendingApprovalCount: pendingApprovals,
        lastActivityAt: parseDate(snapshot.updatedAt, fallback: now),
        summary: redacted(
          snapshot.latestSummary ?? snapshot.finalMessage ?? snapshot.error
            ?? snapshot.prompt
        )
      )
    case .acp(let snapshot):
      return MobileAgentSummary(
        id: snapshot.managedAgentID,
        stationID: stationID,
        sessionID: snapshot.sessionId,
        displayName: redacted(snapshot.displayName),
        family: .acp,
        status: snapshot.status.title,
        role: nil,
        isActive: snapshot.status == .active,
        isBlocked: snapshot.pendingPermissions > 0 || snapshot.status == .awaitingReview,
        pendingPermissionCount: snapshot.pendingPermissions,
        lastActivityAt: parseDate(snapshot.updatedAt, fallback: now),
        summary: redacted(snapshot.stderrTail ?? snapshot.projectDir)
      )
    }
  }

  func mobileReview(
    _ review: ReviewItem,
    filesResponse: ReviewsFilesListResponse? = nil,
    timelineResponse: ReviewsTimelineResponse? = nil,
    now: Date
  ) -> MobileReviewSummary {
    MobileReviewSummary(
      id: review.pullRequestID,
      stationID: stationID,
      repositoryID: review.repositoryID,
      repository: review.repository,
      number: Int(review.number),
      url: redacted(review.url),
      title: redacted(review.title),
      author: redacted(review.authorLogin),
      state: review.state.rawValue,
      checksSummary: review.checkStatus.rawValue,
      headSha: review.headSha,
      mergeable: review.mergeable.rawValue,
      reviewStatus: review.reviewStatus.rawValue,
      checkStatus: review.checkStatus.rawValue,
      policyBlocked: review.policyBlocked,
      isDraft: review.isDraft,
      labels: review.labels.map(redacted),
      checks: review.checks.prefix(6).map(mobileReviewCheck),
      files: (filesResponse?.files ?? []).prefix(8).map(mobileReviewFile),
      activity: (timelineResponse?.entries ?? []).prefix(6).map { entry in
        mobileReviewActivity(entry, now: now)
      },
      additions: review.additions,
      deletions: review.deletions,
      requiredFailedCheckNames: review.requiredFailedCheckNames.map(redacted),
      viewerCanUpdate: review.viewerCanUpdate,
      viewerCanMergeAsAdmin: review.viewerCanMergeAsAdmin,
      filePaginationComplete: filesResponse?.paginationComplete,
      needsYou: needsReviewAttention(review),
      updatedAt: parseDate(review.updatedAt, fallback: now)
    )
  }

  func mobileTaskBoardItem(
    _ item: TaskBoardItem,
    now: Date
  ) -> MobileTaskBoardSummary {
    MobileTaskBoardSummary(
      id: item.id,
      stationID: stationID,
      title: redacted(item.title),
      bodyPreview: redacted(taskBoardBodyPreview(item)),
      status: item.status.rawValue,
      statusTitle: item.status.title,
      priority: item.priority.rawValue,
      priorityTitle: item.priority.title,
      tags: item.tags.map(redacted),
      projectID: redacted(item.projectId),
      sessionID: item.sessionId,
      workItemID: item.workItemId,
      agentMode: item.agentMode.rawValue,
      needsYou: taskBoardItemNeedsYou(item),
      updatedAt: parseDate(item.updatedAt, fallback: now)
    )
  }

  func taskBoardBodyPreview(_ item: TaskBoardItem) -> String {
    let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
    let summary = item.planning.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let source = body.isEmpty ? summary : body
    guard source.count > 180 else {
      return source
    }
    return "\(source.prefix(177))..."
  }

  func taskBoardItemNeedsYou(_ item: TaskBoardItem) -> Bool {
    switch item.status {
    case .planReview, .needsYou, .blocked:
      true
    default:
      false
    }
  }

  func mobileReviewCheck(_ check: ReviewCheck) -> MobileReviewCheckSnippet {
    MobileReviewCheckSnippet(
      id: redacted(check.id),
      name: redacted(check.name),
      status: check.status.rawValue,
      conclusion: check.conclusion.rawValue,
      checkSuiteID: check.checkSuiteID,
      detailsURL: redacted(check.detailsURL)
    )
  }

  func mobileReviewFile(_ file: ReviewFile) -> MobileReviewFileSnippet {
    MobileReviewFileSnippet(
      id: redacted(file.id),
      path: redacted(file.path),
      changeType: file.changeType.rawValue,
      additions: file.additions,
      deletions: file.deletions,
      viewedState: file.viewerViewedState.rawValue,
      isBinary: file.isBinary
    )
  }

  func mobileReviewActivity(
    _ entry: ReviewTimelineEntry,
    now: Date
  ) -> MobileReviewActivitySnippet {
    MobileReviewActivitySnippet(
      id: entry.id,
      kind: entry.kind.rawValue,
      actor: redacted(entry.actor?.login),
      summary: redacted(reviewActivitySummary(entry)),
      recordedAt: parseDate(entry.recordedAt, fallback: now)
    )
  }

  func reviewActivitySummary(_ entry: ReviewTimelineEntry) -> String {
    switch entry {
    case .issueComment:
      "Commented"
    case .review(let payload):
      "Review \(payload.state.rawValue.replacingOccurrences(of: "_", with: " "))"
    case .reviewThread(let payload):
      payload.isResolved ? "Resolved thread on \(payload.path)" : "Thread on \(payload.path)"
    case .commit(let payload):
      "Commit \(payload.abbreviatedOid): \(payload.messageHeadline)"
    case .headRefForcePushed(let payload):
      "Force-pushed \(payload.beforeAbbreviatedOid) -> \(payload.afterAbbreviatedOid)"
    case .simpleActorEvent(let payload):
      simpleActorEventSummary(payload)
    case .unknown(let payload):
      payload.typename
    }
  }

  func simpleActorEventSummary(_ payload: SimpleActorEventPayload) -> String {
    switch payload.eventKind {
    case .labeled:
      return "Added label \(payload.label ?? "label")"
    case .unlabeled:
      return "Removed label \(payload.label ?? "label")"
    case .reviewRequested:
      return "Requested review from \(payload.requestedReviewerLogin ?? "reviewer")"
    case .reviewRequestRemoved:
      return "Removed review request for \(payload.requestedReviewerLogin ?? "reviewer")"
    case .renamedTitle:
      return "Renamed title"
    case .merged:
      return "Merged"
    case .closed:
      return "Closed"
    case .reopened:
      return "Reopened"
    case .readyForReview:
      return "Marked ready for review"
    case .convertToDraft:
      return "Converted to draft"
    case .autoMergeEnabled:
      return "Enabled auto-merge"
    case .autoMergeDisabled:
      return "Disabled auto-merge"
    default:
      return payload.eventKind.rawValue.replacingOccurrences(of: "_", with: " ")
    }
  }
}
