import HarnessMonitorKit

extension AgentsWindowView {
  var canStartTerminal: Bool {
    guard !viewModel.isSubmitting else { return false }
    switch viewModel.selectedLaunchSelection {
    case .tui:
      return viewModel.rows > 0 && viewModel.cols > 0
    case .acp(let id):
      let descriptor = viewModel.availableAcpAgents.first { $0.id == id }
      let probe = viewModel.runtimeProbeResults?.probes.first { $0.agentId == id }
      return descriptor != nil && (probe?.binaryPresent ?? true)
    }
  }

  @MainActor
  func loadAgentPickerCatalogs() async {
    async let tuiRefresh = store.refreshSelectedAgentTuis()
    async let codexRefresh = store.refreshSelectedCodexRuns()
    async let personas = store.fetchPersonas()
    async let runtimeModels = store.fetchRuntimeModelCatalogs()
    async let acpAgents = store.fetchAcpAgentDescriptors()
    async let runtimeProbes = store.fetchRuntimeProbeResults()
    let loadedPersonas = await personas
    let loadedRuntimeModels = await runtimeModels
    let loadedAcpAgents = await acpAgents
    let loadedRuntimeProbes = await runtimeProbes
    _ = await tuiRefresh
    _ = await codexRefresh
    applyLoadedCatalogs(
      personas: loadedPersonas,
      runtimeModels: loadedRuntimeModels,
      acpAgents: loadedAcpAgents,
      runtimeProbeResults: loadedRuntimeProbes
    )
  }

  @MainActor
  private func applyLoadedCatalogs(
    personas: [AgentPersona],
    runtimeModels: [RuntimeModelCatalog],
    acpAgents: [AcpAgentDescriptor],
    runtimeProbeResults: AcpRuntimeProbeResponse?
  ) {
    if viewModel.availablePersonas != personas {
      viewModel.availablePersonas = personas
    }
    if viewModel.availableRuntimeModels != runtimeModels {
      viewModel.availableRuntimeModels = runtimeModels
    }
    if viewModel.availableAcpAgents != acpAgents {
      viewModel.availableAcpAgents = acpAgents
    }
    if viewModel.runtimeProbeResults != runtimeProbeResults {
      viewModel.runtimeProbeResults = runtimeProbeResults
    }
  }
}
