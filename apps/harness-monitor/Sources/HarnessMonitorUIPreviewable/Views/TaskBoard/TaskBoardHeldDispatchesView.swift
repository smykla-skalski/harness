import HarnessMonitorKit
import SwiftUI

struct TaskBoardHeldDispatchesView: View {
  let summary: TaskBoardHeldDispatchSummary

  @State private var isExpanded: Bool

  init(summary: TaskBoardHeldDispatchSummary, initiallyExpanded: Bool = false) {
    self.summary = summary
    _isExpanded = State(initialValue: initiallyExpanded)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      TaskBoardWorkflowSectionHeader(
        title: "Held for delivery",
        systemImage: "pause.circle.fill"
      ) {
        TaskBoardWorkflowStatusPill(
          title: "\(summary.count) held",
          systemImage: "pause.fill",
          tint: HarnessMonitorTheme.caution
        )
      }
      .padding(.horizontal, HarnessMonitorTheme.spacingSM)

      if summary.items.isEmpty {
        TaskBoardReviewMessageCard(
          icon: "tray",
          title: "No held dispatches",
          detail: "All accepted work has been delivered",
          tint: HarnessMonitorTheme.secondaryInk
        )
      } else {
        VStack(spacing: 0) {
          if isExpanded {
            LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
              ForEach(summary.items, id: \.intentId) { item in
                TaskBoardHeldDispatchRow(item: item)
              }
            }
            .padding(HarnessMonitorTheme.spacingSM)

            Divider()
          }

          TaskBoardReviewDisclosureButton(
            collapsedTitle: "Show held dispatches",
            expandedTitle: "Hide held dispatches",
            isExpanded: $isExpanded
          )
        }
        .taskBoardWorkflowCard()
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .animation(nil, value: isExpanded)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.step.held-dispatches")
  }
}

private struct TaskBoardHeldDispatchRow: View {
  let item: TaskBoardHeldDispatchItem

  @Environment(\.fontScale)
  private var fontScale

  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
        Text(item.boardItemId)
          .font(captionSemibold)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(item.boardItemId)
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        Label(ownerKind.title, systemImage: ownerKind.systemImage)
          .font(captionSemibold)
          .foregroundStyle(HarnessMonitorTheme.caution)
          .fixedSize()
      }
      .padding(HarnessMonitorTheme.spacingSM)

      Divider()
      metadataRow(label: "Owner", value: item.ownerId ?? "Unknown owner")
      Divider()
      metadataRow(label: "Work item", value: item.workItemId)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HarnessMonitorTheme.ink.opacity(0.04), in: .rect(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(HarnessMonitorTheme.ink.opacity(0.1))
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.step.held-dispatch.\(item.intentId)")
  }

  private func metadataRow(label: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
      Text(label)
        .font(captionFont)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      Text(value)
        .font(captionFont.monospaced())
        .foregroundStyle(HarnessMonitorTheme.ink)
        .lineLimit(1)
        .truncationMode(.middle)
        .multilineTextAlignment(.trailing)
        .textSelection(.enabled)
        .help(value)
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingSM)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
  }

  private var ownerKind: OwnerKind {
    if item.workspaceId != nil {
      return .workspace
    }
    if item.sessionId != nil {
      return .session
    }
    if item.workingCopyId != nil {
      return .workingCopy
    }
    return .unknown
  }

  private enum OwnerKind {
    case workspace
    case session
    case workingCopy
    case unknown

    var title: String {
      switch self {
      case .workspace: "Workspace"
      case .session: "Session"
      case .workingCopy: "Working copy"
      case .unknown: "Unknown"
      }
    }

    var systemImage: String {
      switch self {
      case .workspace: "square.3.layers.3d"
      case .session: "terminal"
      case .workingCopy: "folder"
      case .unknown: "questionmark.circle"
      }
    }
  }
}
