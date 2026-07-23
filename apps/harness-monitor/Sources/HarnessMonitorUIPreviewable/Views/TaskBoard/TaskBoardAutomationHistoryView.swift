import SwiftUI

struct TaskBoardAutomationHistoryView: View {
  let presentation: TaskBoardAutomationPresentation
  let metrics: TaskBoardOverviewMetrics
  let selectedRunID: String?
  let historyLoad: TaskBoardAutomationHistoryLoad
  let isDetailLoading: Bool
  let isMetricsLoading: Bool
  let hasOlder: Bool
  let isDetailAuthorized: Bool
  let actions: TaskBoardAutomationInspectorActions

  var body: some View {
    TaskBoardOperationsCard(title: "Automation history", metrics: metrics) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        Button {
          actions.enqueueHistoryAndMetricsRefresh()
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
        .harnessNativeFormControl()
        .controlSize(HarnessMonitorControlMetrics.compactControlSize)
        .disabled(historyLoad != .idle)
        .accessibilityIdentifier("harness.task-board.automation.history.refresh")

        Spacer(minLength: 0)

        if historyLoad == .initial {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Loading automation history")
        }
      }
      .padding(.vertical, HarnessMonitorTheme.spacingSM)

      TaskBoardAutomationSubsectionHeader(title: "Metrics")
      if presentation.metricRows.isEmpty {
        TaskBoardAutomationPlaceholder(
          title: isMetricsLoading ? "Loading metrics…" : "Metrics are unavailable",
          systemImage: "chart.bar.xaxis",
          showsProgress: isMetricsLoading
        )
      } else {
        TaskBoardAutomationValueRows(rows: presentation.metricRows)
      }

      TaskBoardAutomationSubsectionHeader(title: "Runs")
      if presentation.historyRuns.isEmpty {
        TaskBoardAutomationPlaceholder(
          title: historyLoad == .initial ? "Loading runs…" : "No automation runs recorded",
          systemImage: "clock.arrow.circlepath",
          showsProgress: historyLoad == .initial
        )
      } else {
        LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          ForEach(presentation.historyRuns) { run in
            runButton(run)
          }
        }
      }

      if hasOlder {
        Button {
          actions.enqueueOlderHistory()
        } label: {
          HStack(spacing: HarnessMonitorTheme.spacingXS) {
            if historyLoad == .older {
              ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            }
            Text(historyLoad == .older ? "Loading Older Runs…" : "Load Older Runs")
          }
        }
        .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
        .harnessNativeFormControl()
        .controlSize(HarnessMonitorControlMetrics.compactControlSize)
        .disabled(historyLoad != .idle)
        .padding(.top, HarnessMonitorTheme.spacingMD)
        .accessibilityIdentifier("harness.task-board.automation.history.older")
      }

      TaskBoardAutomationSubsectionHeader(title: "Run detail")
      detailContent
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.automation.history")
  }

  private func runButton(_ run: TaskBoardAutomationRunRow) -> some View {
    Button {
      actions.enqueueRunDetail(runID: run.id)
    } label: {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
          Text(run.title)
            .font(.caption.monospaced().weight(.semibold))
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer(minLength: 0)
          Text(run.state)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(run.tone.color)
        }
        Text(run.subtitle)
          .font(.caption2)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(2)
        Text(run.startedAt)
          .font(.caption2.monospacedDigit())
          .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
          .help(run.accessibilityTimestamp)
      }
      .padding(HarnessMonitorTheme.spacingSM)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        selectedRunID == run.id
          ? HarnessMonitorTheme.accent.opacity(0.12)
          : HarnessMonitorTheme.ink.opacity(0.04),
        in: .rect(cornerRadius: HarnessMonitorTheme.cornerRadiusSM)
      )
      .overlay {
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM)
          .strokeBorder(
            selectedRunID == run.id
              ? HarnessMonitorTheme.accent.opacity(0.55)
              : HarnessMonitorTheme.controlBorder.opacity(0.3)
          )
      }
    }
    .harnessInteractiveCardButtonStyle(
      cornerRadius: HarnessMonitorTheme.cornerRadiusSM,
      tint: selectedRunID == run.id ? HarnessMonitorTheme.accent : nil
    )
    .disabled(!isDetailAuthorized)
    .help(isDetailAuthorized ? "Inspect run detail" : "Run detail requires operator write access")
    .accessibilityElement(children: .combine)
    .accessibilityValue("\(run.state), started \(run.accessibilityTimestamp)")
    .accessibilityIdentifier(TaskBoardAutomationAccessibility.runRowID(for: run.id))
  }

  @ViewBuilder private var detailContent: some View {
    if !isDetailAuthorized {
      TaskBoardAutomationPlaceholder(
        title: "Run detail requires operator write access",
        systemImage: "lock.fill"
      )
    } else if isDetailLoading {
      TaskBoardAutomationPlaceholder(
        title: "Loading run detail…",
        systemImage: "doc.text.magnifyingglass",
        showsProgress: true
      )
    } else if let detail = presentation.detail {
      Text(detail.runID)
        .font(.caption.monospaced().weight(.semibold))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      TaskBoardAutomationValueRows(rows: detail.rows)

      if let error = detail.error {
        Label(
          detail.errorKind.map { "\($0): \(error)" } ?? error,
          systemImage: "exclamationmark.octagon.fill"
        )
        .font(.caption)
        .foregroundStyle(HarnessMonitorTheme.danger)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, HarnessMonitorTheme.spacingSM)
      }

      TaskBoardAutomationSubsectionHeader(title: "Stages")
      if detail.stages.isEmpty {
        TaskBoardAutomationPlaceholder(
          title: "No stages recorded for this run",
          systemImage: "list.number"
        )
      } else {
        LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          ForEach(detail.stages) { stage in
            stageRow(stage)
          }
        }
      }
    } else {
      TaskBoardAutomationPlaceholder(
        title: selectedRunID == nil
          ? "Select a run to inspect its stages"
          : "Run detail unavailable",
        systemImage: "doc.text.magnifyingglass"
      )
    }
  }

  private func stageRow(_ stage: TaskBoardAutomationStageRow) -> some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
      Text(String(stage.sequence))
        .font(.caption2.monospacedDigit().weight(.semibold))
        .foregroundStyle(stage.tone.color)
        .frame(minWidth: 22, alignment: .trailing)
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
          Text(stage.title)
            .font(.caption.weight(.semibold))
          Spacer(minLength: 0)
          Text(stage.state)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(stage.tone.color)
        }
        if let summary = stage.summary {
          Text(summary)
            .font(.caption2)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
        }
        Text(stage.recordedAt)
          .font(.caption2.monospacedDigit())
          .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
          .help(stage.accessibilityTimestamp)
      }
    }
    .padding(HarnessMonitorTheme.spacingSM)
    .background(HarnessMonitorTheme.ink.opacity(0.04), in: .rect(cornerRadius: 8))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(TaskBoardAutomationAccessibility.stageRowID(for: stage.id))
  }
}
