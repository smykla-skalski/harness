import Foundation
import HarnessMonitorKit
import HarnessMonitorPolicyCanvas
import SwiftUI

@MainActor
final class DashboardPolicyCanvasViewModelStore: ObservableObject {
  @Published var viewModel: PolicyCanvasViewModel

  init(
    document: TaskBoardPolicyPipelineDocument?,
    simulation: TaskBoardPolicyPipelineSimulationResult?,
    audit: TaskBoardPolicyPipelineAuditSummary?,
    activeCanvasId: String?,
    workspace: TaskBoardPolicyCanvasWorkspace?
  ) {
    viewModel = PolicyCanvasViewModel.liveStartupState(
      document: document,
      simulation: simulation,
      audit: audit,
      activeCanvasId: activeCanvasId,
      workspace: workspace
    )
  }
}

struct DashboardPolicyCanvasRefreshTaskID: Equatable {
  let isRouteVisible: Bool
  let connectionState: HarnessMonitorStore.ConnectionState
  let needsInitialRefresh: Bool
}
