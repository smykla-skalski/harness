import Foundation

extension HarnessMonitorStore {
  func mutateAgentTui(
    using client: any HarnessMonitorClientProtocol,
    actionName: String? = nil,
    selectUpdatedSnapshot: Bool = false,
    mutation: @escaping @Sendable () async throws -> AgentTuiSnapshot,
    staleTuiID: String? = nil
  ) async -> Bool {
    await mutateAgentTuiSnapshot(
      using: client,
      actionName: actionName,
      selectUpdatedSnapshot: selectUpdatedSnapshot,
      mutation: mutation,
      staleTuiID: staleTuiID
    ) != nil
  }

  func mutateAgentTuiSnapshot(
    using client: any HarnessMonitorClientProtocol,
    actionName: String? = nil,
    selectUpdatedSnapshot: Bool = false,
    mutation: @escaping @Sendable () async throws -> AgentTuiSnapshot,
    staleTuiID: String? = nil
  ) async -> AgentTuiSnapshot? {
    do {
      let measuredTui = try await Self.measureOperation {
        try await mutation()
      }
      recordRequestSuccess()
      clearHostBridgeIssue(for: "agent-tui")
      applyAgentTui(measuredTui.value)
      if selectUpdatedSnapshot {
        selectAgentTui(tuiID: measuredTui.value.tuiId)
      }
      scheduleAgentTuiActionRefresh(using: client, baseline: measuredTui.value)
      if let actionName {
        presentSuccessFeedback(actionName)
      }
      return measuredTui.value
    } catch {
      _ = applyAgentTuiError(
        error,
        selectedSessionID: selectedSessionID,
        staleTuiID: staleTuiID
      )
      return nil
    }
  }

  func applyAgentTuiError(
    _ error: any Error,
    selectedSessionID: String?,
    staleTuiID: String? = nil
  ) -> Bool {
    guard selectedSessionID == self.selectedSessionID else {
      return false
    }
    if let staleTuiID, reconcileStaleManagedAgentError(error, tuiID: staleTuiID) {
      return false
    }
    if let apiError = error as? HarnessMonitorAPIError,
      case .server(let code, _) = apiError,
      code == 501
    {
      markHostBridgeIssue(for: "agent-tui", statusCode: code)
    }
    presentFailureFeedback(error.localizedDescription)
    return false
  }

  func scheduleAgentTuiActionRefresh(
    using client: any HarnessMonitorClientProtocol,
    baseline: AgentTuiSnapshot
  ) {
    guard baseline.status.isActive else {
      cancelAgentTuiActionRefresh(for: baseline.tuiId)
      return
    }

    agentTuiActionRefreshSequence &+= 1
    let token = agentTuiActionRefreshSequence
    pendingAgentTuiActionRefresh = (tuiID: baseline.tuiId, token: token)
    agentTuiActionRefreshTask?.cancel()
    agentTuiActionRefreshTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }

      defer {
        if pendingAgentTuiActionRefresh?.token == token {
          pendingAgentTuiActionRefresh = nil
          agentTuiActionRefreshTask = nil
        }
      }

      for _ in 0..<Self.agentTuiActionRefreshAttempts {
        try? await Task.sleep(for: Self.agentTuiActionRefreshDelay)
        guard !Task.isCancelled else {
          return
        }
        guard
          pendingAgentTuiActionRefresh?.token == token,
          pendingAgentTuiActionRefresh?.tuiID == baseline.tuiId,
          selectedAgentTui?.tuiId == baseline.tuiId
        else {
          return
        }
        // Keep the corrective GET alive for stale equal-or-older streaming snapshots.
        if (selectedAgentTui?.updatedAt ?? "") > baseline.updatedAt {
          return
        }
        let updated = await refreshAgentTuiAfterAction(using: client, baseline: baseline)
        if updated || selectedAgentTui?.status.isActive != true {
          return
        }
      }
    }
  }

  func cancelAgentTuiActionRefresh(for tuiID: String? = nil) {
    guard tuiID == nil || pendingAgentTuiActionRefresh?.tuiID == tuiID else {
      return
    }

    pendingAgentTuiActionRefresh = nil
    agentTuiActionRefreshTask?.cancel()
    agentTuiActionRefreshTask = nil
  }

  func refreshAgentTuiAfterAction(
    using client: any HarnessMonitorClientProtocol,
    baseline: AgentTuiSnapshot
  ) async -> Bool {
    do {
      let measuredTui = try await Self.measureOperation {
        try await client.agentTui(tuiID: baseline.tuiId)
      }
      recordRequestSuccess()
      guard selectedAgentTui?.tuiId == baseline.tuiId else {
        return true
      }
      clearHostBridgeIssue(for: "agent-tui")
      applyAgentTui(measuredTui.value)
      return measuredTui.value != baseline
    } catch {
      let tuiId = baseline.tuiId
      let err = error.localizedDescription
      HarnessMonitorLogger.store.warning(
        "terminal agent post-action refresh failed for \(tuiId, privacy: .public): \(err, privacy: .public)"
      )
      if reconcileStaleManagedAgentError(error, tuiID: baseline.tuiId) {
        return true
      }
      return true
    }
  }

  func reconcileStaleManagedAgentError(
    _ error: any Error,
    tuiID: String
  ) -> Bool {
    guard isStaleManagedAgentError(error, tuiID: tuiID) else {
      return false
    }
    cancelAgentTuiActionRefresh(for: tuiID)
    let remainingTuis = selectedAgentTuis.filter { $0.tuiId != tuiID }
    assignAgentTuis(remainingTuis, selected: preferredAgentTui(from: remainingTuis))
    return true
  }

  func isStaleManagedAgentError(
    _ error: any Error,
    tuiID: String
  ) -> Bool {
    guard let apiError = error as? HarnessMonitorAPIError,
      case .server(let code, _) = apiError,
      code == 400 || code == 404
    else {
      return false
    }
    let message = apiError.serverMessage ?? error.localizedDescription
    return
      apiError.serverSemanticCode == "KSRCLI090"
      || message.contains("managed agent '\(tuiID)' not found")
      || message.contains("terminal agent '\(tuiID)' not found")
      || message.contains("terminal agent '\(tuiID)' is not active")
  }

  func preferredAgentTui(from tuis: [AgentTuiSnapshot]) -> AgentTuiSnapshot? {
    if let selectedTuiID = selectedAgentTui?.tuiId,
      let selectedTui = tuis.first(where: { $0.tuiId == selectedTuiID })
    {
      return selectedTui
    }
    return tuis.first(where: { $0.status.isActive }) ?? tuis.first
  }
}
