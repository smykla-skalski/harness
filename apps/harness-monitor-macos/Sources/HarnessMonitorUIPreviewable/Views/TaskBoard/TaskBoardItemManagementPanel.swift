import Foundation
import HarnessMonitorKit
import SwiftUI

struct TaskBoardItemManagementPanel: View {
  let item: TaskBoardItem
  let metrics: TaskBoardOverviewMetrics
  let isActionInFlight: Bool
  let onRunOnce: ((TaskBoardItem) -> Void)?
  let onEvaluate: ((TaskBoardItem) -> Void)?
  let onRefresh: (() -> Void)?
  let onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: metrics.managementPanelSpacing) {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
        Label("Manage Board Item", systemImage: "slider.horizontal.3")
          .scaledFont(.subheadline.weight(.semibold))
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        Button(action: onClose) {
          Image(systemName: "xmark")
            .accessibilityHidden(true)
        }
        .buttonStyle(.borderless)
        .frame(minWidth: metrics.iconControlMinWidth, minHeight: metrics.controlMinHeight)
        .help("Close board item")
        .accessibilityLabel("Close item panel")
      }

      Text(item.title)
        .scaledFont(.body.weight(.semibold))
        .lineLimit(2)
        .textSelection(.enabled)

      if !item.body.isEmpty {
        Text(item.body)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(6)
          .textSelection(.enabled)
      }

      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        managementPill(item.status.title, tint: taskBoardStatusColor(for: item.status))
        managementPill(item.priority.title, tint: priorityColor(for: item.priority))
        managementPill(item.hasLinkedSessionTask ? "Session Task" : "Board Only", tint: linkTint)
      }

      TaskBoardManagementFacts(facts: managementFacts)

      if !externalDestinations.isEmpty {
        TaskBoardExternalLinks(destinations: externalDestinations, metrics: metrics)
      }

      ViewThatFits(in: .horizontal) {
        HStack(spacing: HarnessMonitorTheme.spacingSM) {
          actionButtons
        }
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          actionButtons
        }
      }
    }
    .padding(HarnessMonitorTheme.spacingMD)
    .frame(maxWidth: .infinity, minHeight: metrics.managementPanelMinHeight, alignment: .leading)
    .background(
      .background.opacity(0.56),
      in: .rect(cornerRadius: metrics.managementPanelCornerRadius)
    )
    .overlay(
      RoundedRectangle(cornerRadius: metrics.managementPanelCornerRadius)
        .stroke(HarnessMonitorTheme.controlBorder.opacity(0.62), lineWidth: 1)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.manage-item.\(item.id)")
  }

  @ViewBuilder private var actionButtons: some View {
    Button {
      onRunOnce?(item)
    } label: {
      Label("Run Once", systemImage: "play.circle")
        .scaledFont(.caption.weight(.semibold))
    }
    .frame(minHeight: metrics.controlMinHeight)
    .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
    .disabled(isActionInFlight || onRunOnce == nil)

    Button {
      onEvaluate?(item)
    } label: {
      Label("Evaluate Item", systemImage: "checkmark.seal")
        .scaledFont(.caption.weight(.semibold))
    }
    .frame(minHeight: metrics.controlMinHeight)
    .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
    .disabled(isActionInFlight || onEvaluate == nil)
    .help("Evaluate this board item")

    Button {
      onRefresh?()
    } label: {
      Label("Refresh", systemImage: "arrow.clockwise")
        .scaledFont(.caption.weight(.semibold))
    }
    .frame(minHeight: metrics.controlMinHeight)
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
    .disabled(isActionInFlight || onRefresh == nil)
    .help("Refresh task board")
    .accessibilityIdentifier("harness.task-board.manage-item.refresh")
  }

  private var linkTint: Color {
    item.hasLinkedSessionTask ? HarnessMonitorTheme.accent : HarnessMonitorTheme.caution
  }

  private var managementFacts: [TaskBoardManagementFact] {
    var facts = [
      TaskBoardManagementFact("ID", value: item.id),
      TaskBoardManagementFact("Mode", value: item.agentMode.title),
    ]
    if let projectId = item.projectId {
      facts.append(TaskBoardManagementFact("Project", value: projectId))
    }
    if let worktree = item.workflow?.worktree {
      facts.append(TaskBoardManagementFact("Worktree", value: worktree))
    }
    if let branch = item.workflow?.branch {
      facts.append(TaskBoardManagementFact("Branch", value: branch))
    }
    if let workflow = item.workflow {
      facts.append(TaskBoardManagementFact("Workflow", value: workflow.status.title))
    }
    if !item.tags.isEmpty {
      facts.append(TaskBoardManagementFact("Tags", value: item.tags.joined(separator: ", ")))
    }
    return facts
  }

  private var externalDestinations: [TaskBoardExternalDestination] {
    var destinations = item.externalRefs.compactMap { ref -> TaskBoardExternalDestination? in
      guard let rawURL = ref.url, let url = URL(string: rawURL) else {
        return nil
      }
      return TaskBoardExternalDestination(label: externalLabel(for: ref), url: url)
    }
    if let prUrl = item.workflow?.prUrl, let url = URL(string: prUrl) {
      destinations.append(TaskBoardExternalDestination(label: "Pull Request", url: url))
    }
    return destinations
  }

  private func externalLabel(for ref: TaskBoardExternalRef) -> String {
    switch ref.provider {
    case .gitHub:
      "GitHub \(ref.externalId)"
    case .todoist:
      "Todoist \(ref.externalId)"
    }
  }

  private func managementPill(_ label: String, tint: Color) -> some View {
    Text(label)
      .scaledFont(.caption2.weight(.bold))
      .foregroundStyle(tint)
      .lineLimit(1)
      .padding(.horizontal, HarnessMonitorTheme.spacingSM)
      .padding(.vertical, metrics.managementPillVerticalPadding)
      .background(tint.opacity(0.12), in: .capsule)
  }
}

private struct TaskBoardManagementFact: Identifiable {
  let id: String
  let label: String
  let value: String

  init(_ label: String, value: String) {
    id = label
    self.label = label
    self.value = value
  }
}

private struct TaskBoardExternalDestination: Identifiable {
  let label: String
  let url: URL

  var id: URL { url }
}

private struct TaskBoardManagementFacts: View {
  let facts: [TaskBoardManagementFact]

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: HarnessMonitorTheme.spacingMD) {
      ForEach(facts) { fact in
        GridRow {
          Text(fact.label)
            .scaledFont(.caption.weight(.semibold))
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          Text(fact.value)
            .scaledFont(.caption)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
      }
    }
  }
}

private struct TaskBoardExternalLinks: View {
  let destinations: [TaskBoardExternalDestination]
  let metrics: TaskBoardOverviewMetrics

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        links
      }
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        links
      }
    }
  }

  @ViewBuilder private var links: some View {
    ForEach(destinations) { destination in
      Link(destination: destination.url) {
        Label(destination.label, systemImage: "arrow.up.right.square")
          .scaledFont(.caption.weight(.semibold))
      }
      .frame(minHeight: metrics.controlMinHeight)
      .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .help("Open \(destination.label)")
    }
  }
}

extension TaskBoardWorkflowStatus {
  fileprivate var title: String {
    switch self {
    case .idle:
      "Idle"
    case .running:
      "Running"
    case .paused:
      "Paused"
    case .completed:
      "Completed"
    case .failed:
      "Failed"
    case .cancelled:
      "Cancelled"
    }
  }
}
