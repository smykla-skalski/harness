import HarnessMonitorKit
import SwiftUI

#Preview("Workspace - Create") {
  workspaceWindowPreview(
    store: AgentTuiPreviewSupport.makeStore(
      tuis: [],
      bridgeState: .ready
    )
  )
}

#Preview("Workspace - Create With Recovery") {
  workspaceWindowPreview(
    store: AgentTuiPreviewSupport.makeStore(
      tuis: [],
      bridgeState: .excluded
    )
  )
}

#Preview("Workspace - Running Session") {
  workspaceWindowPreview(
    store: AgentTuiPreviewSupport.makeStore(
      tuis: AgentTuiPreviewSupport.runningSingle,
      selectedTuiID: AgentTuiPreviewSupport.runningSingle.first?.tuiId
    )
  )
}

#Preview("Workspace - Stopped Session") {
  workspaceWindowPreview(
    store: AgentTuiPreviewSupport.makeStore(
      tuis: AgentTuiPreviewSupport.stoppedSingle,
      selectedTuiID: AgentTuiPreviewSupport.stoppedSingle.first?.tuiId
    )
  )
}

#Preview("Workspace - Multiple Sessions") {
  workspaceWindowPreview(
    width: 980,
    store: AgentTuiPreviewSupport.makeStore(
      tuis: Array(AgentTuiPreviewSupport.overflowMixed.prefix(3)),
      selectedTuiID: AgentTuiPreviewSupport.overflowMixed[1].tuiId
    )
  )
}

#Preview("Workspace - Many Sessions") {
  workspaceWindowPreview(
    width: 980,
    store: AgentTuiPreviewSupport.makeStore(
      tuis: AgentTuiPreviewSupport.overflowMixed,
      selectedTuiID: AgentTuiPreviewSupport.overflowMixed[4].tuiId
    )
  )
}

#Preview("Workspace - Mixed Sessions") {
  workspaceWindowPreview(
    width: 980,
    store: AgentTuiPreviewSupport.makeStore(
      tuis: AgentTuiPreviewSupport.overflowMixed,
      selectedTuiID: AgentTuiPreviewSupport.overflowMixed[5].tuiId
    )
  )
}

#Preview("Workspace - ACP Leader Create") {
  workspaceWindowAcpLeaderPreview()
}

@MainActor
private func workspaceWindowPreview(
  width: CGFloat = 980,
  height: CGFloat = 660,
  store: HarnessMonitorStore
) -> some View {
  WorkspaceWindowView(store: store)
    .frame(width: width, height: height)
    .padding()
}

@MainActor
private func workspaceWindowAcpLeaderPreview(
  width: CGFloat = 1_140,
  height: CGFloat = 900
) -> some View {
  let store = AgentTuiPreviewSupport.makeStore(tuis: [], bridgeState: .ready)
  let view = WorkspaceWindowView(store: store)
  view.viewModel.createMode = .terminal
  view.viewModel.selectedLaunchSelection = .acp("copilot")
  view.viewModel.runtime = .copilot
  view.viewModel.availableAcpAgents = PreviewHarnessClient.previewAcpAgentDescriptors
  view.viewModel.availablePersonas = PreviewHarnessClient.previewPersonas
  view.viewModel.availableRuntimeModels = PreviewHarnessClient.previewRuntimeModelCatalogs
  view.viewModel.runtimeProbeResults = PreviewHarnessClient.previewRuntimeProbeResults()
  view.viewModel.selectedRole = .leader
  view.viewModel.selectedAcpFallbackRole = .observer
  view.viewModel.selectedPersona = "reviewer"
  if let copilotCatalog = PreviewHarnessClient.previewRuntimeModelCatalogs.first(
    where: { $0.runtime == AgentTuiRuntime.copilot.rawValue }
  ) {
    view.viewModel.selectedTerminalModelByRuntime[.copilot] = copilotCatalog.default
    view.viewModel.selectedTerminalEffortByRuntime[.copilot] = "medium"
  }
  view.viewModel.name = "Copilot Reviewer"
  view.viewModel.prompt = "Review the latest ACP wiring and call out the next risky change."
  view.viewModel.projectDir = "/tmp/ui-acp"
  return
    view
    .frame(width: width, height: height)
    .padding()
}
