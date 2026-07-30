import HarnessMonitorKit
import SwiftUI

struct TaskBoardItemWorkflowProgressSection: View {
  let item: TaskBoardItem
  let actions: TaskBoardOverviewActions
  let state: TaskBoardWorkflowProgressState
  @Environment(\.fontScale)
  private var fontScale

  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      header
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.manage-item.workflow-progress")
  }

  private var header: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingXS) {
      Label("Dependency Workflow", systemImage: "point.3.connected.trianglepath.dotted")
        .font(captionSemibold)
        .foregroundStyle(HarnessMonitorTheme.ink)
        .accessibilityAddTraits(.isHeader)
      if let phase = state.progress?.phase {
        Text("·")
          .font(captionFont)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .accessibilityHidden(true)
        Text(phase.displayTitle)
          .font(captionFont)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(1)
      }
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      if let progress = state.progress {
        statusPill(progress.state)
      }
    }
  }

  @ViewBuilder private var content: some View {
    if let progress = state.progress {
      progressContent(progress)
    } else if state.isLoading {
      HarnessMonitorLoadingStateView(title: "Loading workflow progress")
    } else if state.didFail {
      TaskBoardReviewMessageCard(
        icon: "exclamationmark.triangle.fill",
        title: "Workflow progress unavailable",
        detail: "The daemon could not load the durable workflow audit trail",
        tint: HarnessMonitorTheme.caution
      ) {
        Button("Retry") { reload() }
          .font(captionSemibold)
          .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      }
    } else {
      TaskBoardReviewMessageCard(
        icon: "clock",
        title: "Waiting to start",
        detail: "No dependency workflow execution has been recorded",
        tint: HarnessMonitorTheme.secondaryInk
      )
    }
  }

  private func progressContent(_ progress: TaskBoardWorkflowProgress) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
      TaskBoardWorkflowMetadataCard(
        provenance: TaskBoardReviewProvenance(
          executionID: progress.executionId,
          repository: progress.triage?.repository ?? item.executionRepository,
          pullRequestNumber: progress.triage?.pullRequestNumber ?? item.workflow?.prNumber,
          requestedRuntime: progress.currentRuntime ?? "Not started",
          actualRuntime: nil,
          model: progress.currentModel,
          headRevision: progress.exactHeadRevision,
          startedAt: progress.createdAt,
          finishedAt: progress.completedAt
        )
      )
      if let blockedReason = progress.blockedReason {
        humanActionCard(title: "Blocked", detail: blockedReason)
      }
      if let terminal = progress.terminalOutcome {
        TaskBoardReviewMessageCard(
          icon: terminal.kind == .succeeded ? "checkmark.circle.fill" : "hand.raised.fill",
          title: terminal.kind.displayTitle,
          detail: terminal.summary.withoutTrailingPeriod,
          tint: terminal.kind == .succeeded
            ? HarnessMonitorTheme.success
            : HarnessMonitorTheme.caution
        )
      }
      if let triage = progress.triage {
        triageSection(triage)
      }
      attemptsSection(progress.attempts)
    }
  }

  private func triageSection(_ route: TaskBoardDependencyRouteRecord) -> some View {
    let triage = route.sourceResult
    let dependencyChange =
      "\(triage.dependency.name) \(triage.dependency.currentVersion) → \(triage.dependency.targetVersion)"
    return VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        TaskBoardWorkflowSectionHeader(
          title: "Dependency triage",
          systemImage: "checklist.checked"
        ) {
          TaskBoardWorkflowStatusPill(
            title: triage.disposition.displayTitle,
            systemImage: triage.disposition.systemImage,
            tint: triage.disposition.tint
          )
        }
        .padding(.leading, HarnessMonitorTheme.spacingSM)
        TaskBoardWorkflowTriageCard(
          dependencyChange: dependencyChange,
          safetyAssessment: triage.safetyAssumption,
          requiredTools: triage.requiredTools
        )
      }
      checksSection(triage.checks)
      nextStepsSection(triage.nextSteps)
      if case .humanRequired(let unmetRequirement) = route.status {
        humanActionCard(title: "Human action required", detail: unmetRequirement)
      }
    }
  }

  @ViewBuilder private func checksSection(_ checks: [TaskBoardDependencyCheck]) -> some View {
    if !checks.isEmpty {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        TaskBoardWorkflowSectionHeader(title: "Checks", systemImage: "checkmark.circle")
          .padding(.horizontal, HarnessMonitorTheme.spacingSM)
        TaskBoardWorkflowChecksCard(checks: checks)
      }
    }
  }

  @ViewBuilder
  private func nextStepsSection(_ steps: [TaskBoardDependencyTriageStep]) -> some View {
    if !steps.isEmpty {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        TaskBoardWorkflowSectionHeader(title: "Next steps", systemImage: "list.number")
          .padding(.horizontal, HarnessMonitorTheme.spacingSM)
        TaskBoardWorkflowStepsCard(steps: steps)
      }
    }
  }

  private func attemptsSection(_ attempts: [TaskBoardWorkflowAttemptProgress]) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      TaskBoardWorkflowSectionHeader(
        title: "Attempts",
        systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90"
      ) {
        Text("\(attempts.count)")
          .font(captionSemibold.monospacedDigit())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize()
      }
      .padding(.horizontal, HarnessMonitorTheme.spacingSM)
      if attempts.isEmpty {
        Text("No fixer or verification attempt has started")
          .font(captionFont)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .padding(HarnessMonitorTheme.spacingSM)
      } else {
        TaskBoardWorkflowAttemptsCard(attempts: attempts)
      }
    }
  }

  private func humanActionCard(title: String, detail: String) -> some View {
    TaskBoardReviewMessageCard(
      icon: "hand.raised.fill",
      title: title,
      detail: detail.withoutTrailingPeriod,
      tint: HarnessMonitorTheme.caution
    )
  }

  private func statusPill(_ status: TaskBoardExecutionState) -> some View {
    TaskBoardWorkflowStatusPill(
      title: status.displayTitle,
      systemImage: status.systemImage,
      tint: status.tint
    )
  }

  private func reload() {
    let store = actions.store
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Reloading task board workflow progress") {
        await state.load(item: item, store: store)
      }
    )
  }
}

extension TaskBoardItem {
  var showsWorkflowProgress: Bool {
    switch workflowKind {
    case .prFix, .prFixReview:
      true
    default:
      false
    }
  }
}

extension String {
  var displayTitle: String {
    replacingOccurrences(of: "_", with: " ")
      .split(separator: " ")
      .map { $0.capitalized }
      .joined(separator: " ")
  }
}

extension TaskBoardExecutionPhase {
  var displayTitle: String { rawValue.displayTitle }
}

extension TaskBoardExecutionState {
  var displayTitle: String { rawValue.displayTitle }
  var systemImage: String {
    switch self {
    case .completed: "checkmark.circle.fill"
    case .failed: "xmark.octagon.fill"
    case .cancelled: "slash.circle.fill"
    case .humanRequired, .blocked: "hand.raised.fill"
    case .retryWait, .awaitingApproval: "clock.fill"
    default: "bolt.fill"
    }
  }
  var tint: Color {
    switch self {
    case .completed: HarnessMonitorTheme.success
    case .failed: HarnessMonitorTheme.danger
    case .cancelled, .humanRequired, .blocked, .retryWait, .awaitingApproval:
      HarnessMonitorTheme.caution
    default: HarnessMonitorTheme.accent
    }
  }
}

extension TaskBoardAttemptState {
  var displayTitle: String { rawValue.displayTitle }
  var systemImage: String {
    switch self {
    case .completed: "checkmark.circle.fill"
    case .failed, .unknown: "xmark.octagon.fill"
    case .cancelled: "slash.circle.fill"
    case .retryWait: "clock.fill"
    default: "bolt.fill"
    }
  }
  var tint: Color {
    switch self {
    case .completed: HarnessMonitorTheme.success
    case .failed, .unknown: HarnessMonitorTheme.danger
    case .cancelled, .retryWait: HarnessMonitorTheme.caution
    default: HarnessMonitorTheme.accent
    }
  }
}

extension TaskBoardTerminalOutcomeKind {
  var displayTitle: String { rawValue.displayTitle }
}

extension TaskBoardDependencyTriageDisposition {
  var displayTitle: String { rawValue.displayTitle }
  var systemImage: String {
    switch self {
    case .continueSafe, .reportOnly: "checkmark.shield.fill"
    case .waitForChecks: "clock.badge.questionmark"
    case .fixRequired: "wrench.and.screwdriver.fill"
    case .humanRequired: "hand.raised.fill"
    }
  }
  var tint: Color {
    switch self {
    case .continueSafe, .reportOnly: HarnessMonitorTheme.success
    case .waitForChecks, .humanRequired: HarnessMonitorTheme.caution
    case .fixRequired: HarnessMonitorTheme.accent
    }
  }
}

extension TaskBoardDependencyCheckState {
  var displayTitle: String { rawValue.displayTitle }
  var systemImage: String {
    switch self {
    case .passed: "checkmark.circle.fill"
    case .failed: "xmark.octagon.fill"
    case .pending: "clock.fill"
    case .cancelled: "slash.circle.fill"
    case .skipped: "forward.fill"
    }
  }
  var tint: Color {
    switch self {
    case .passed: HarnessMonitorTheme.success
    case .failed: HarnessMonitorTheme.danger
    case .pending, .cancelled: HarnessMonitorTheme.caution
    case .skipped: HarnessMonitorTheme.secondaryInk
    }
  }
}
