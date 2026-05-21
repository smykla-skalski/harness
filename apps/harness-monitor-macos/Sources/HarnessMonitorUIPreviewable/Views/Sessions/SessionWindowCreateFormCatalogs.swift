import Foundation
import HarnessMonitorKit

enum SessionWindowCreateFormCatalogs {
  enum RuntimeCustomModel {
    static let tag = "__custom__"
  }

  static let allEffortLevels: [String] = ["off", "low", "medium", "high", "xhigh"]
  // Keep Claude ACP out of the New Agent form until the bundled Harness adapter lands.
  private static let deferredAcpDescriptorIDsForNewAgentForm: Set<String> = ["claude"]

  static func capabilityOptions(
    acpAgents: [AcpAgentDescriptor],
    runtimeProbeResults: AcpRuntimeProbeResponse?,
    sandboxed: Bool = false,
    acpHostBridgeReady: Bool = true,
    codexHostBridgeReady: Bool = true
  ) -> [AgentCapabilityOption] {
    AgentCapabilityCatalog.options(
      acpAgents: acpAgents.filter {
        !deferredAcpDescriptorIDsForNewAgentForm.contains($0.id)
      },
      runtimeProbeResults: runtimeProbeResults,
      sandboxed: sandboxed,
      acpHostBridgeReady: acpHostBridgeReady,
      codexHostBridgeReady: codexHostBridgeReady
    )
  }

  @MainActor
  static func fallbackAgentOptions(store: HarnessMonitorStore) -> [AgentCapabilityOption] {
    capabilityOptions(
      acpAgents: [],
      runtimeProbeResults: nil,
      sandboxed: store.daemonStatus?.manifest?.sandboxed == true,
      acpHostBridgeReady: store.hostBridgeCapabilityState(for: "acp") == .ready,
      codexHostBridgeReady: store.hostBridgeCapabilityState(for: "codex") == .ready
    )
  }

  @MainActor
  static func loadAgentCatalogState(
    store: HarnessMonitorStore
  ) async -> SessionWindowAgentCreateCatalogState {
    async let acpAgents = store.fetchAcpAgentDescriptors()
    async let runtimeProbeResults = store.fetchRuntimeProbeResults()
    async let runtimeModelCatalogs = store.fetchRuntimeModelCatalogs()
    async let personas = store.fetchPersonas()

    let descriptors = await acpAgents
    let probes = await runtimeProbeResults
    let runtimeModels = await runtimeModelCatalogs
    let availablePersonas = await personas

    return SessionWindowAgentCreateCatalogState(
      descriptors: descriptors,
      runtimeModelCatalogs: runtimeModels,
      capabilityOptions: capabilityOptions(
        acpAgents: descriptors,
        runtimeProbeResults: probes,
        sandboxed: store.daemonStatus?.manifest?.sandboxed == true,
        acpHostBridgeReady: store.hostBridgeCapabilityState(for: "acp") == .ready,
        codexHostBridgeReady: store.hostBridgeCapabilityState(for: "codex") == .ready
      ),
      personas: availablePersonas,
      isLoading: false,
      hasLoaded: true
    )
  }

  @MainActor
  static func loadAgentCatalogStateIfNeeded(
    store: HarnessMonitorStore,
    state: SessionWindowStateCache,
    draft: SessionCreateDraft
  ) async {
    guard draft.kind == .agent else { return }
    if state.agentCreateCatalog.hasLoaded {
      normalizeDraftIfNeeded(store: store, state: state, draft: draft)
      return
    }

    if !state.beginAgentCreateCatalogLoading() {
      while state.agentCreateCatalog.isLoading {
        await Task.yield()
      }
      normalizeDraftIfNeeded(store: store, state: state, draft: draft)
      return
    }

    let catalogState = await loadAgentCatalogState(store: store)
    state.finishAgentCreateCatalogLoading(
      descriptors: catalogState.descriptors,
      runtimeModelCatalogs: catalogState.runtimeModelCatalogs,
      capabilityOptions: catalogState.capabilityOptions,
      personas: catalogState.personas
    )
    normalizeDraftIfNeeded(store: store, state: state, draft: draft)
  }

  @MainActor
  static func normalizeDraftIfNeeded(
    store: HarnessMonitorStore,
    state: SessionWindowStateCache,
    draft: SessionCreateDraft
  ) {
    let options = activeAgentOptions(catalogState: state.agentCreateCatalog, store: store)
    let currentDraft = state.sectionState.createDrafts[draft.kind] ?? draft
    let normalized = normalizedLaunchSelection(
      draft: currentDraft,
      options: options,
      didPickLaunchSelectionManually: state.didPickCreateLaunchSelectionManually(
        for: currentDraft.kind
      )
    )
    if normalized.storageKey != currentDraft.launchSelection.storageKey {
      var next = currentDraft
      next.runtime = normalized.storageKey
      state.updateCreateDraft(next)
    }
  }

  @MainActor
  static func activeAgentOptions(
    catalogState: SessionWindowAgentCreateCatalogState,
    store: HarnessMonitorStore
  ) -> [AgentCapabilityOption] {
    let options =
      catalogState.capabilityOptions.isEmpty
      ? fallbackAgentOptions(store: store)
      : catalogState.capabilityOptions
    return refreshedCapabilityOptions(
      options,
      sandboxed: store.daemonStatus?.manifest?.sandboxed == true,
      acpHostBridgeReady: store.hostBridgeCapabilityState(for: "acp") == .ready,
      codexHostBridgeReady: store.hostBridgeCapabilityState(for: "codex") == .ready
    )
  }

  static func refreshedCapabilityOptions(
    _ options: [AgentCapabilityOption],
    sandboxed: Bool,
    acpHostBridgeReady: Bool,
    codexHostBridgeReady: Bool
  ) -> [AgentCapabilityOption] {
    options.map {
      $0.refreshingAvailability(
        sandboxed: sandboxed,
        acpHostBridgeReady: acpHostBridgeReady,
        codexHostBridgeReady: codexHostBridgeReady
      )
    }
  }

  static func shouldSurfaceInlineUnavailableReason(
    for option: AgentCapabilityOption
  ) -> Bool {
    option.availabilityState != .bridgeAccessRequired
  }

  static func shouldShowTransportDiagnosticsDisclosure(
    for option: AgentCapabilityOption
  ) -> Bool {
    switch option.availabilityState {
    case .checkingAccess, .setupRequired, .unavailable:
      return true
    case .projectAccessAvailable, .bridgeAccessRequired, .terminalOnly:
      return false
    }
  }

  static func transportSummary(
    option: AgentCapabilityOption,
    choice: AgentCapabilityTransportChoice
  ) -> String {
    if choice.id.isCodexNative {
      return "Starts via Codex app server"
    }

    if choice.id.isAcp {
      return "Starts via ACP"
    }

    switch option.availabilityState {
    case .projectAccessAvailable:
      return "Opens in Terminal. ACP is also available"
    case .checkingAccess:
      return "Opens in Terminal while ACP is checked"
    case .setupRequired:
      return "Opens in Terminal. Set up ACP when you're ready"
    case .bridgeAccessRequired:
      return "Opens in Terminal. Turn on bridge access to use ACP"
    case .terminalOnly:
      return "Opens in Terminal"
    case .unavailable:
      return option.projectAccessGuidanceText ?? "This provider isn't available yet"
    }
  }
}

extension SessionCreateDraft {
  var launchSelection: AgentLaunchSelection {
    AgentLaunchSelection(storageKey: runtime)
      ?? AgentTuiRuntime(rawValue: runtime).map(AgentLaunchSelection.tui)
      ?? HarnessMonitorAgentLaunchDefaults.startupFallbackSelection
  }
}
