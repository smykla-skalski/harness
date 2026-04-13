import Foundation

extension HarnessMonitorStore {
  private func applyHostBridgeStatus(_ status: BridgeStatusReport) {
    guard let daemonStatus else {
      return
    }
    self.daemonStatus = daemonStatus.updating(hostBridge: status.hostBridgeManifest)
  }

  /// Apply a lightweight in-place manifest update triggered by the
  /// `ManifestWatcher` file-system event. Refreshes `daemonStatus` with the
  /// new `hostBridge` snapshot and clears any transient
  /// `hostBridgeCapabilityIssues` picked up from earlier 501/503 responses,
  /// so stale "unavailable" flags do not shadow a freshly-healthy bridge.
  /// Preserves launch agent, project counts, diagnostics, and every other
  /// daemon status field.
  ///
  /// Also emits a `.info` entry in the connection timeline so operators
  /// can see revision transitions in the visible event log without
  /// grepping the unified log. No `reconnect`, no HTTP round-trip, no
  /// stream teardown - exactly one observable slice assignment on the
  /// MainActor per update.
  ///
  /// No-op when `daemonStatus` is nil (bootstrap has not finished) - the
  /// initial `daemonStatus` assignment will carry the latest manifest
  /// anyway via `refreshDaemonStatus`.
  func applyManifestRevision(_ manifest: DaemonManifest) {
    guard let current = daemonStatus else {
      return
    }
    daemonStatus = current.updating(hostBridge: manifest.hostBridge)
    clearTransientHostBridgeIssues()
    appendConnectionEvent(
      kind: .info,
      detail: "Daemon host bridge refreshed (revision \(manifest.revision))"
    )
  }

  /// Read the manifest file from disk and call `applyManifestRevision` if the
  /// host bridge state changed. This is the 10s fallback for when the
  /// DispatchSource watcher stops firing.
  ///
  /// Missing manifests remain a no-op. Read and decode failures append one
  /// visible `.error` breadcrumb so stale host-bridge state does not fail
  /// silently. Decoder is allocated once per call - this method only runs in
  /// the background probe task, never in a view body.
  func refreshBridgeStateFromManifest(at manifestURL: URL = HarnessMonitorPaths.manifestURL()) {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: manifestURL.path) else { return }
    guard let data = fileManager.contents(atPath: manifestURL.path) else {
      recordManifestRefreshFailure(
        "Failed to read daemon manifest at \(manifestURL.path)"
      )
      return
    }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let manifest: DaemonManifest
    do {
      manifest = try decoder.decode(DaemonManifest.self, from: data)
    } catch {
      recordManifestRefreshFailure(
        "Failed to decode daemon manifest at \(manifestURL.path): \(error.localizedDescription)"
      )
      return
    }
    guard daemonStatus?.manifest?.hostBridge != manifest.hostBridge else { return }
    applyManifestRevision(manifest)
  }

  private func recordManifestRefreshFailure(_ detail: String) {
    guard connectionEvents.last?.detail != detail else {
      return
    }
    appendConnectionEvent(kind: .error, detail: detail)
  }

  func mutateHostBridgeCapability(
    using client: any HarnessMonitorClientProtocol,
    capability: String,
    enabled: Bool,
    force: Bool
  ) async -> HostBridgeCapabilityMutationResult {
    do {
      let measuredStatus = try await measureHostBridgeCapabilityMutation(
        using: client,
        capability: capability,
        enabled: enabled,
        force: force
      )
      applyHostBridgeCapabilityMutationSuccess(
        capability: capability,
        enabled: enabled,
        status: measuredStatus.value
      )
      return .success
    } catch let apiError as HarnessMonitorAPIError {
      if case .server(let code, let message) = apiError, code == 409 {
        return .requiresForce(message)
      }
      if case .server(let code, _) = apiError, code == 404 {
        return await recoverMissingHostBridgeReconfigureRoute(
          capability: capability,
          enabled: enabled,
          force: force
        )
      }
      if case .server(let code, let message) = apiError,
        code == 400,
        message.localizedCaseInsensitiveContains("bridge is not running")
      {
        applyStoppedHostBridgeState()
        let friendlyMessage = "The shared host bridge is not running. Start it and try again."
        appendConnectionEvent(kind: .error, detail: friendlyMessage)
        presentFailureFeedback(friendlyMessage)
        return .failed
      }
      if case .server(let code, _) = apiError, code == 501 || code == 503 {
        markHostBridgeIssue(for: capability, statusCode: code)
      }
      presentFailureFeedback(apiError.localizedDescription)
      return .failed
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return .failed
    }
  }

  private func measureHostBridgeCapabilityMutation(
    using client: any HarnessMonitorClientProtocol,
    capability: String,
    enabled: Bool,
    force: Bool
  ) async throws -> MeasuredOperation<BridgeStatusReport> {
    try await Self.measureOperation {
      try await client.reconfigureHostBridge(
        request: HostBridgeReconfigureRequest(
          enable: enabled ? [capability] : [],
          disable: enabled ? [] : [capability],
          force: force
        )
      )
    }
  }

  private func applyHostBridgeCapabilityMutationSuccess(
    capability: String,
    enabled: Bool,
    status: BridgeStatusReport
  ) {
    recordRequestSuccess()
    clearHostBridgeIssue(for: capability)
    applyHostBridgeStatus(status)
    if capability == "agent-tui" && !enabled {
      cancelAgentTuiActionRefresh()
      selectedAgentTuis = []
      selectedAgentTui = nil
    }
    presentSuccessFeedback(hostBridgeActionLabel(for: capability, enabled: enabled))
  }

  private func applyStoppedHostBridgeState() {
    clearTransientHostBridgeIssues()
    if let daemonStatus {
      self.daemonStatus = daemonStatus.updating(hostBridge: HostBridgeManifest())
    }
  }

  private func recoverMissingHostBridgeReconfigureRoute(
    capability: String,
    enabled: Bool,
    force: Bool
  ) async -> HostBridgeCapabilityMutationResult {
    switch daemonOwnership {
    case .external:
      let message =
        "Connected daemon does not support live host bridge reconfiguration yet. "
        + "Restart `harness daemon dev` and try again."
      appendConnectionEvent(kind: .error, detail: message)
      presentFailureFeedback(message)
      return .failed
    case .managed:
      appendConnectionEvent(
        kind: .reconnecting,
        detail: "Restarting the managed daemon to pick up host bridge reconfigure support"
      )
      do {
        let recoveredClient = try await restartManagedDaemonForHostBridgeReconfigure()
        let measuredStatus = try await measureHostBridgeCapabilityMutation(
          using: recoveredClient,
          capability: capability,
          enabled: enabled,
          force: force
        )
        applyHostBridgeCapabilityMutationSuccess(
          capability: capability,
          enabled: enabled,
          status: measuredStatus.value
        )
        return .success
      } catch {
        presentFailureFeedback(error.localizedDescription)
        return .failed
      }
    }
  }

  private func restartManagedDaemonForHostBridgeReconfigure() async throws
    -> any HarnessMonitorClientProtocol
  {
    stopAllStreams()
    let staleClient = client
    client = nil
    if let staleClient {
      await staleClient.shutdown()
    }

    _ = try await daemonController.stopDaemon()
    let registrationState = try await daemonController.registerLaunchAgent()
    switch registrationState {
    case .enabled:
      break
    case .requiresApproval:
      throw DaemonControlError.commandFailed(
        "Launch agent needs approval in System Settings > General > Login Items."
      )
    case .notRegistered, .notFound:
      throw DaemonControlError.commandFailed("Launch agent registration did not complete.")
    }

    let refreshedClient = try await daemonController.awaitManifestWarmUp(
      timeout: bootstrapWarmUpTimeout
    )
    await connect(using: refreshedClient)
    guard connectionState == .online else {
      throw DaemonControlError.commandFailed(
        "The harness daemon did not become healthy before the timeout."
      )
    }
    return refreshedClient
  }

  private func hostBridgeActionLabel(for capability: String, enabled: Bool) -> String {
    let capabilityName =
      switch capability {
      case "agent-tui":
        "Agent TUI"
      case "codex":
        "Codex"
      default:
        capability.replacingOccurrences(of: "-", with: " ").capitalized
      }
    return enabled
      ? "Enabled \(capabilityName) host bridge" : "Disabled \(capabilityName) host bridge"
  }
}
