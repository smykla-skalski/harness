import HarnessMonitorKit
import SwiftUI

/// What the dispatched worker reported against this item: its state, the
/// percentage it last claimed, the attempt behind a review handoff, and its
/// append-only checkpoint log.
struct TaskBoardItemWorkerProgressSection: View {
  let item: TaskBoardItem
  let actions: TaskBoardOverviewActions
  let state: TaskBoardWorkerProgressState
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration

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
    .accessibilityIdentifier("harness.task-board.manage-item.worker-progress")
  }

  private var header: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingXS) {
      Label("Worker Progress", systemImage: "figure.walk.motion")
        .font(captionSemibold)
        .foregroundStyle(HarnessMonitorTheme.ink)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      if let progress = state.progress {
        TaskBoardWorkflowStatusPill(
          title: progress.state.displayTitle,
          systemImage: progress.state.systemImage,
          tint: progress.state.tint
        )
      }
    }
  }

  @ViewBuilder private var content: some View {
    if let presentation = state.presentation {
      progressContent(presentation)
    } else if state.isLoading {
      HarnessMonitorLoadingStateView(title: "Loading worker progress")
    } else if state.didFail {
      TaskBoardReviewMessageCard(
        icon: "exclamationmark.triangle.fill",
        title: "Worker progress unavailable",
        detail: "The daemon could not load this item's durable worker progress",
        tint: HarnessMonitorTheme.caution
      ) {
        Button("Retry") { reload() }
          .font(captionSemibold)
          .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      }
    } else {
      TaskBoardReviewMessageCard(
        icon: "clock",
        title: "Not dispatched",
        detail: "No worker has been started for this item yet",
        tint: HarnessMonitorTheme.secondaryInk
      )
    }
  }

  private func progressContent(
    _ presentation: TaskBoardWorkerProgressPresentation
  ) -> some View {
    let progress = presentation.progress
    return VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
      if let summary = progress.summary, !summary.isEmpty {
        TaskBoardReviewMessageCard(
          icon: progress.state.systemImage,
          title: progress.state.displayTitle,
          detail: summary.withoutTrailingPeriod,
          tint: progress.state.tint
        )
      }
      if let blockedReason = progress.blockedReason, !blockedReason.isEmpty {
        TaskBoardReviewMessageCard(
          icon: "hand.raised.fill",
          title: "Blocked",
          detail: blockedReason.withoutTrailingPeriod,
          tint: HarnessMonitorTheme.danger
        )
      }
      if let percent = progress.progressPercent {
        TaskBoardWorkerProgressBar(percent: percent)
      }
      metadataCard(presentation)
      checkpointsSection(presentation.checkpoints)
    }
  }

  private func metadataCard(
    _ presentation: TaskBoardWorkerProgressPresentation
  ) -> some View {
    let progress = presentation.progress
    return VStack(spacing: 0) {
      TaskBoardWorkflowValueRow(
        label: "Work item",
        value: progress.workItemId,
        monospaced: true
      )
      Divider()
      TaskBoardWorkflowValueRow(
        label: "Attempt",
        value: progress.attemptId ?? "Unavailable",
        monospaced: progress.attemptId != nil
      )
      Divider()
      TaskBoardWorkflowValueRow(
        label: "Item revision",
        value: progress.itemRevision.map(String.init) ?? "Unavailable"
      )
      Divider()
      TaskBoardWorkflowValueRow(
        label: "Last report",
        value: formatTimestamp(presentation.updatedAt, configuration: dateTimeConfiguration)
      )
      if let completedAt = presentation.completedAt {
        Divider()
        TaskBoardWorkflowValueRow(
          label: "Settled",
          value: formatTimestamp(completedAt, configuration: dateTimeConfiguration)
        )
      }
    }
    .taskBoardWorkflowCard()
  }

  @ViewBuilder
  private func checkpointsSection(
    _ checkpoints: [TaskBoardWorkerCheckpointPresentation]
  ) -> some View {
    if checkpoints.isEmpty {
      TaskBoardReviewMessageCard(
        icon: "text.append",
        title: "No checkpoints",
        detail: "The worker has not recorded a checkpoint yet",
        tint: HarnessMonitorTheme.secondaryInk
      )
    } else {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        TaskBoardWorkflowSectionHeader(title: "Checkpoints", systemImage: "text.append") {
          Text("\(checkpoints.count)")
            .font(captionSemibold.monospacedDigit())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
        .padding(.horizontal, HarnessMonitorTheme.spacingSM)
        TaskBoardWorkerCheckpointsCard(checkpoints: checkpoints)
      }
    }
  }

  private func reload() {
    let store = actions.store
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Reloading task board worker progress") {
        await state.load(item: item, store: store)
      }
    )
  }
}

extension TaskBoardItem {
  /// A worker record exists only once the item has been dispatched, which is
  /// exactly when it carries a work item id.
  var showsWorkerProgress: Bool {
    guard let workItemId else { return false }
    return !workItemId.isEmpty
  }
}
