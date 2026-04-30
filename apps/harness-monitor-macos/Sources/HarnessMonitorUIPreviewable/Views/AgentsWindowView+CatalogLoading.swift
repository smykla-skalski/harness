import HarnessMonitorKit

extension AgentsWindowView {
  struct ManagedSelectionRefreshOutcome {
    let agentTuisDidRefresh: Bool
    let codexRunsDidRefresh: Bool

    var didRefreshManagedSelections: Bool {
      agentTuisDidRefresh || codexRunsDidRefresh
    }
  }

  func applyManagedSelectionFreshness(_ outcome: ManagedSelectionRefreshOutcome) {
    if outcome.agentTuisDidRefresh {
      viewModel.hasFreshManagedAgentTuis = true
    }
    if outcome.codexRunsDidRefresh {
      viewModel.hasFreshManagedCodexRuns = true
    }
  }

  var canStartTerminal: Bool {
    guard !viewModel.isSubmitting else { return false }
    switch viewModel.selectedLaunchSelection {
    case .tui:
      return viewModel.rows > 0 && viewModel.cols > 0
    case .acp(let id):
      guard
        let option = agentCapabilityOptions.first(where: { option in
          option.transportChoices.contains { $0.id == .acp(id) }
        })
      else {
        return false
      }
      return option.isEnabled(option.transportChoice(for: .acp(id)))
    }
  }

  @MainActor
  func refreshManagedSelections() async -> ManagedSelectionRefreshOutcome {
    async let tuiRefresh = store.refreshSelectedAgentTuis()
    async let codexRefresh = store.refreshSelectedCodexRuns()
    return ManagedSelectionRefreshOutcome(
      agentTuisDidRefresh: await tuiRefresh,
      codexRunsDidRefresh: await codexRefresh
    )
  }

  @MainActor
  func loadAgentPickerCatalogs() async {
    async let personas = store.fetchPersonas()
    async let runtimeModels = store.fetchRuntimeModelCatalogs()
    async let acpAgents = store.fetchAcpAgentDescriptors()
    async let runtimeProbes = store.fetchRuntimeProbeResults()
    let loadedPersonas = await personas
    let loadedRuntimeModels = await runtimeModels
    let loadedAcpAgents = await acpAgents
    let loadedRuntimeProbes = await runtimeProbes
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
