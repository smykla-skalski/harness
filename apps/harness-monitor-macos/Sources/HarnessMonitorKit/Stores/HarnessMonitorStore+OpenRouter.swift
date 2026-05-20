import Foundation

/// OpenRouter session orchestration on top of the generic ACP managed-agent
/// surface.
///
/// The daemon dispatches OpenRouter through the catalog descriptor
/// `"openrouter"`. The store projects each returned `AcpAgentSnapshot` into an
/// `OpenRouterRunSnapshot` for the existing OpenRouter UI surfaces.

/// Catalog descriptor id the daemon uses to dispatch OpenRouter sessions.
public enum OpenRouterAcpDispatch {
  public static let descriptorID = "openrouter"
  public static let defaultModel = "anthropic/claude-3.7-sonnet"
}

/// Curated fallback list shown in the picker when the user has no pinned,
/// recent, or frequent models yet and the daemon could not return a dynamic
/// catalog. Kept narrow and current-generation so the empty state is never
/// stale; the dynamic catalog overrides this as soon as it loads.
public enum OpenRouterPopularModels {
  public static let modelIDs: [String] = [
    "anthropic/claude-opus-4",
    "anthropic/claude-sonnet-4",
    "openai/gpt-5",
    "openai/gpt-4o",
    "google/gemini-2.5-pro",
    "google/gemini-2.5-flash",
    "xai/grok-4",
    "deepseek/deepseek-r1",
    "meta-llama/llama-4-maverick",
    "qwen/qwen3-coder",
  ]
}

extension HarnessMonitorStore {
  /// Catalog descriptor id the daemon uses to dispatch OpenRouter sessions.
  public static var openRouterDescriptorID: String { OpenRouterAcpDispatch.descriptorID }

  /// Default model picked when a caller does not supply one.
  public static var defaultOpenRouterModel: String { OpenRouterAcpDispatch.defaultModel }

  public func openRouterRuns(forSessionID sessionID: String) -> [OpenRouterRunSnapshot] {
    openRouterRunsBySessionID[sessionID] ?? []
  }

  @discardableResult
  public func startOpenRouterRun(
    prompt: String,
    model: String?,
    displayName: String? = nil,
    sessionAgentID: String? = nil,
    projectDir: String? = nil,
    sessionID: String? = nil
  ) async -> OpenRouterRunSnapshot? {
    let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedModel = trimmedModel?.nonEmpty ?? Self.defaultOpenRouterModel
    let resolvedName =
      displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
      ?? "OpenRouter"

    guard
      let acp = await startAcpAgent(
        descriptorID: AcpDescriptorID(rawValue: Self.openRouterDescriptorID),
        capabilities: [],
        name: resolvedName,
        prompt: prompt,
        projectDir: projectDir,
        model: resolvedModel,
        allowCustomModel: true,
        sessionID: sessionID
      )
    else {
      return nil
    }

    registerOpenRouterRunMetadata(
      runID: acp.acpId,
      model: resolvedModel,
      displayName: resolvedName
    )
    openRouterModelUsage.recordUsage(of: resolvedModel)
    let run = OpenRouterRunSnapshot(
      acp: acp,
      model: resolvedModel,
      displayName: resolvedName
    )
    applyOpenRouterRun(run)
    return run
  }

  @discardableResult
  public func promptOpenRouterRun(
    runID: String,
    prompt: String
  ) async -> OpenRouterRunSnapshot? {
    guard let client else { return nil }
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      presentFailureFeedback("OpenRouter prompt cannot be empty")
      return nil
    }
    do {
      let snapshot = try await client.promptManagedAcpAgent(agentID: runID, prompt: trimmed)
      guard case .acp(let acp) = snapshot else { return nil }
      let metadata = openRouterRunMetadata[runID]
      if let model = metadata?.model, !model.isEmpty {
        openRouterModelUsage.recordUsage(of: model)
      }
      let projected = OpenRouterRunSnapshot(
        acp: acp,
        model: metadata?.model ?? "",
        displayName: metadata?.displayName
      )
      applyOpenRouterRun(projected)
      return projected
    } catch {
      presentFailureFeedback(
        "Failed to send OpenRouter follow-up: \(error.localizedDescription)"
      )
      return nil
    }
  }

  @discardableResult
  public func cancelOpenRouterRun(runID: String) async -> OpenRouterRunSnapshot? {
    guard let client else { return nil }
    do {
      let snapshot = try await client.stopManagedAcpAgent(agentID: runID)
      guard case .acp(let acp) = snapshot else { return nil }
      let metadata = openRouterRunMetadata[runID]
      let projected = OpenRouterRunSnapshot(
        acp: acp,
        model: metadata?.model ?? "",
        displayName: metadata?.displayName
      )
      applyOpenRouterRun(projected)
      return projected
    } catch {
      presentFailureFeedback(
        "Failed to cancel OpenRouter session: \(error.localizedDescription)"
      )
      return nil
    }
  }

  /// The OpenRouter sheet's model picker source.
  ///
  /// Calls the daemon's dynamic openrouter.list_models endpoint, which
  /// caches the OpenRouter /api/v1/models response for 30 minutes. Falls
  /// back to the static descriptor catalog when the dynamic fetch fails
  /// (typically: no API key configured, or upstream unreachable).
  public func fetchOpenRouterModels() async -> [OpenRouterModelEntry] {
    if let dynamic = try? await client?.openRouterModelCatalog(), !dynamic.models.isEmpty {
      return dynamic.models
    }
    let descriptors = await fetchAcpAgentDescriptors()
    guard
      let descriptor = descriptors.first(where: { $0.id == Self.openRouterDescriptorID }),
      let catalog = descriptor.modelCatalog
    else {
      return []
    }
    return catalog.models.map { model in
      OpenRouterModelEntry(
        id: model.id,
        name: model.displayName,
        contextLength: nil,
        supportedParameters: []
      )
    }
  }

  @discardableResult
  public func resolveOpenRouterPermissionBatch(
    runID: String,
    batchID: String,
    decision: AcpPermissionDecision
  ) async -> ManagedAgentSnapshot? {
    guard let client else { return nil }
    do {
      let snapshot = try await client.resolveManagedAcpPermission(
        agentID: runID,
        batchID: batchID,
        decision: decision
      )
      if case .acp(let acp) = snapshot {
        let metadata = openRouterRunMetadata[runID]
        let projected = OpenRouterRunSnapshot(
          acp: acp,
          model: metadata?.model ?? "",
          displayName: metadata?.displayName
        )
        applyOpenRouterRun(projected)
      }
      return snapshot
    } catch {
      presentFailureFeedback(
        "Failed to resolve permission batch: \(error.localizedDescription)"
      )
      return nil
    }
  }

  func applyOpenRouterRun(_ run: OpenRouterRunSnapshot) {
    var runs = openRouterRunsBySessionID[run.sessionId] ?? []
    if let index = runs.firstIndex(where: { $0.runId == run.runId }) {
      runs[index] = run
    } else {
      runs.append(run)
    }
    openRouterRunsBySessionID[run.sessionId] = runs
  }

  func refreshOpenRouterRuns(
    using _: any HarnessMonitorClientProtocol,
    sessionID _: String
  ) async {
    // OpenRouter runs are projected from ACP snapshots emitted on the daemon
    // push event stream. The store mirrors snapshots into
    // `openRouterRunsBySessionID` when start completes and when a permission
    // batch resolves; no separate transport refresh is required.
  }

  func registerOpenRouterRunMetadata(
    runID: String,
    model: String,
    displayName: String?
  ) {
    openRouterRunMetadata[runID] = OpenRouterRunMetadata(
      model: model,
      displayName: displayName
    )
  }
}

/// Per-run metadata that the daemon's ACP snapshot does not surface
/// (model id, friendly display name). Populated at session start and reused
/// across subsequent snapshot projections.
public struct OpenRouterRunMetadata: Sendable, Equatable {
  public let model: String
  public let displayName: String?

  public init(model: String, displayName: String?) {
    self.model = model
    self.displayName = displayName
  }
}

extension String {
  fileprivate var nonEmpty: String? {
    isEmpty ? nil : self
  }
}
