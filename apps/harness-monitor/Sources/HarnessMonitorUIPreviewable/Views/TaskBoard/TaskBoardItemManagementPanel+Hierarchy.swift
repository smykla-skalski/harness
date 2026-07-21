import HarnessMonitorKit
import SwiftUI

/// Backlink + children rows for the management panel. Held together with the
/// panel's own `selectionModel`/`actions` (not a closure) so navigating away
/// re-targets the same sheet through the board's existing selection
/// machinery, matching how every other card open/select already works.
struct TaskBoardManagementHierarchySection: View {
  let backlink: TaskBoardParentBacklink
  let childrenSummary: TaskBoardUmbrellaChildrenSummary?
  let metrics: TaskBoardOverviewMetrics
  let selectionModel: TaskBoardCardSelectionModel
  let actions: TaskBoardOverviewActions
  @Environment(\.fontScale)
  private var fontScale

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }
  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  private var hasContent: Bool {
    backlink != .none || childrenSummary != nil
  }

  var body: some View {
    if hasContent {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        backlinkRow
        childrenSection
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("harness.task-board.manage-item.hierarchy")
    }
  }

  @ViewBuilder private var backlinkRow: some View {
    switch backlink {
    case .none:
      EmptyView()
    case .resolved(let parent):
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        Text("Belongs to")
          .font(captionSemibold)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Button {
          open(parent)
        } label: {
          Text(parent.title)
            .font(captionFont)
            .lineLimit(1)
        }
        .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
        .controlSize(HarnessMonitorControlMetrics.compactControlSize)
        .accessibilityIdentifier("harness.task-board.manage-item.hierarchy.parent")
      }
    case .outsideCurrentView:
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        Text("Belongs to")
          .font(captionSemibold)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Text("Parent not shown here")
          .font(captionFont)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .accessibilityIdentifier("harness.task-board.manage-item.hierarchy.parent-outside-view")
      }
    }
  }

  @ViewBuilder private var childrenSection: some View {
    if let childrenSummary {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Text("Children")
          .font(captionSemibold)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        if childrenSummary.visibleChildren.isEmpty && childrenSummary.hiddenChildren.isEmpty {
          Text("No children yet")
            .font(captionFont)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        } else {
          ForEach(childrenSummary.visibleChildren) { child in
            childRow(child)
          }
        }
        if let notShownMessage = childrenSummary.notShownMessage {
          Text(notShownMessage)
            .font(captionFont)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .accessibilityIdentifier("harness.task-board.manage-item.hierarchy.hidden-count")
        }
      }
    }
  }

  private func childRow(_ child: TaskBoardItem) -> some View {
    Button {
      open(child)
    } label: {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        Text(child.title)
          .font(captionFont)
          .lineLimit(1)
        Spacer(minLength: HarnessMonitorTheme.spacingXS)
        TaskBoardManagementPill(
          label: child.status.title,
          tint: taskBoardStatusColor(for: child.status),
          verticalPadding: metrics.managementPillVerticalPadding
        )
      }
      .frame(maxWidth: .infinity)
    }
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
    .accessibilityIdentifier("harness.task-board.manage-item.hierarchy.child.\(child.id)")
  }

  private func open(_ item: TaskBoardItem) {
    selectionModel.openAPIItem(item, actions: actions)
  }
}
