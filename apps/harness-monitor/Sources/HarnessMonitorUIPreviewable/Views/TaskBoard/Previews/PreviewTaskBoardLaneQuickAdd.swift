import HarnessMonitorKit
import SwiftUI

#Preview("Task Board Lane Quick Add") {
  HStack(alignment: .top, spacing: 24) {
    LaneQuickAddSample(caption: "Closed", lane: .todo, isOpen: false)
    LaneQuickAddSample(caption: "Open", lane: .todo, isOpen: true)
    LaneQuickAddSample(caption: "Lane that takes no task", lane: .umbrella, isOpen: false)
  }
  .padding(24)
}

/// A lane card cut down to what the affordance sits in: header, body, and the
/// quick add pinned under it. The umbrella sample shows the lane that offers
/// none.
private struct LaneQuickAddSample: View {
  let caption: String
  let lane: TaskBoardInboxLane
  let isOpen: Bool
  @State private var selectionModel = TaskBoardCardSelectionModel()
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }

  private var actions: TaskBoardOverviewActions {
    TaskBoardOverviewActions(store: nil, scope: .dashboard)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(caption)
        .font(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      laneCard
    }
    .task {
      guard isOpen else { return }
      selectionModel.beginQuickAdd(in: lane)
    }
  }

  private var laneCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      TaskBoardLaneHeader(
        lane: lane,
        count: 0,
        collapseOverridesRawValue: .constant("")
      )

      TaskBoardEmptyLane(lane: lane)
        .padding(.horizontal, metrics.laneInnerPadding)
        .padding(.top, metrics.laneHeaderBodyTopPadding)
        .padding(.bottom, metrics.laneInnerPadding)
        .frame(maxHeight: .infinity, alignment: .top)

      if lane.acceptsQuickAddedTask {
        TaskBoardLaneQuickAddRow(
          lane: lane,
          selectionModel: selectionModel,
          actions: actions
        )
      }
    }
    .frame(height: 320)
    .taskBoardLaneColumnChrome(lane: lane)
  }
}
