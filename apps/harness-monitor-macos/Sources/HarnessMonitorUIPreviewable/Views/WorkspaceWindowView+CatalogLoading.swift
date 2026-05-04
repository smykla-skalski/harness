import Foundation
import HarnessMonitorKit

extension WorkspaceWindowView {
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
    guard !viewModel.isSubmitting, createPaneSessionActionUnavailableNote == nil else {
      return false
    }
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
    normalizePreferredLaunchSelection(
      acpAgents: acpAgents,
      runtimeProbeResults: runtimeProbeResults
    )
  }

  @MainActor
  func reloadAgentPickerCatalogsIfPending() async {
    guard !viewModel.didApplyLaunchSelectionAutoDefault else { return }
    await loadAgentPickerCatalogs()
  }

  struct AgentLaunchAvailabilitySignal: Equatable {
    let sandboxed: Bool
    let acpIssue: HarnessMonitorStore.HostBridgeCapabilityIssue?
  }

  var agentLaunchAvailabilitySignal: AgentLaunchAvailabilitySignal {
    AgentLaunchAvailabilitySignal(
      sandboxed: store.daemonStatus?.manifest?.sandboxed ?? false,
      acpIssue: store.hostBridgeCapabilityIssues["acp"]
    )
  }

  @MainActor
  private func normalizePreferredLaunchSelection(
    acpAgents: [AcpAgentDescriptor],
    runtimeProbeResults: AcpRuntimeProbeResponse?
  ) {
    let options = Self.agentCapabilityOptions(
      acpAgents: acpAgents,
      runtimeProbeResults: runtimeProbeResults,
      sandboxed: store.daemonStatus?.manifest?.sandboxed == true,
      acpHostBridgeReady: store.hostBridgeCapabilityState(for: "acp") == .ready
    )

    let resolvedSelection = resolveSelectionApplyingAcpDefaultIfFresh(options: options)

    let normalizedSelection = Self.normalizedLaunchSelection(
      options: options,
      selection: resolvedSelection,
      fallbackRuntime: viewModel.runtime
    )
    if viewModel.selectedLaunchSelection != normalizedSelection {
      viewModel.selectedLaunchSelection = normalizedSelection
    }
    let preferredRuntime = normalizedSelection.preferredRuntime
    if viewModel.runtime != preferredRuntime {
      viewModel.runtime = preferredRuntime
    }
  }

  @MainActor
  private func resolveSelectionApplyingAcpDefaultIfFresh(
    options: [AgentCapabilityOption]
  ) -> AgentLaunchSelection {
    defer { viewModel.didEvaluateInitialLaunchAutoDefault = true }

    if viewModel.didApplyLaunchSelectionAutoDefault {
      return viewModel.selectedLaunchSelection
    }

    let hasStoredSnapshot = LaunchPresetDefaults.read() != nil
    let hasStoredPreferredSelection =
      UserDefaults.standard.string(
        forKey: HarnessMonitorAgentLaunchDefaults.preferredSelectionKey
      ) != nil
    if hasStoredSnapshot || hasStoredPreferredSelection {
      viewModel.didApplyLaunchSelectionAutoDefault = true
      return viewModel.selectedLaunchSelection
    }

    let isSubsequentEvaluation = viewModel.didEvaluateInitialLaunchAutoDefault
    let formIsVisible = viewModel.selection == .create
    if isSubsequentEvaluation && formIsVisible {
      viewModel.didApplyLaunchSelectionAutoDefault = true
      return viewModel.selectedLaunchSelection
    }

    guard
      let acpEnabledOption = options.first(where: { option in
        option.transportChoices.contains { $0.id.isAcp && option.isEnabled($0) }
      }),
      let acpChoice = acpEnabledOption.transportChoices.first(where: {
        $0.id.isAcp && acpEnabledOption.isEnabled($0)
      })
    else {
      return viewModel.selectedLaunchSelection
    }
    viewModel.didApplyLaunchSelectionAutoDefault = true
    return acpChoice.id
  }
}
