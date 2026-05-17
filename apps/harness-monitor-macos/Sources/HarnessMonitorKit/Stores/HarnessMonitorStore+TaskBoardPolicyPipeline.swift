import Foundation

extension HarnessMonitorStore {
  nonisolated static func loadTaskBoardPolicyPipelineSnapshot(
    using client: any HarnessMonitorClientProtocol
  ) async -> MeasuredOperation<TaskBoardPolicyPipelineDocument?> {
    do {
      let measuredPipeline = try await measureOperation {
        try await client.taskBoardPolicyPipeline()
      }
      return MeasuredOperation(value: measuredPipeline.value, latencyMs: measuredPipeline.latencyMs)
    } catch {
      let description = RefreshSnapshotErrorFormatting.describeUnderlying(error)
      HarnessMonitorLogger.store.debug(
        "task-board policy pipeline unavailable during refresh: \(description, privacy: .public)"
      )
      return MeasuredOperation(value: nil, latencyMs: 0)
    }
  }

  public func refreshTaskBoardPolicyPipeline() async {
    guard let client else {
      return
    }
    async let pipeline = Self.loadTaskBoardPolicyPipelineSnapshot(using: client)
    async let audit = loadTaskBoardPolicyAudit(using: client)
    let measuredPipeline = await pipeline
    let measuredAudit = await audit

    withUISyncBatch {
      globalTaskBoardPolicyPipeline = measuredPipeline.value
      globalTaskBoardPolicyAudit = measuredAudit
    }
    await applyTaskBoardPolicyPipelineSupervisorOverrides(measuredPipeline.value)
  }

  @discardableResult
  public func saveTaskBoardPolicyPipelineDraft(
    document: TaskBoardPolicyPipelineDocument
  ) async -> Bool {
    guard let client else {
      return false
    }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let response = try await client.saveTaskBoardPolicyPipelineDraft(
        request: TaskBoardPolicyPipelineSaveDraftRequest(document: document)
      )
      recordRequestSuccess()
      globalTaskBoardPolicyPipeline = response.document
      await applyTaskBoardPolicyPipelineSupervisorOverrides(response.document)
      if response.validation.isValid {
        presentSuccessFeedback("Saved policy draft")
      } else {
        presentFailureFeedback(
          response.validation.issues.first?.message ?? "Policy draft is invalid"
        )
      }
      return response.validation.isValid
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  @discardableResult
  public func simulateTaskBoardPolicyPipeline(
    document: TaskBoardPolicyPipelineDocument? = nil
  ) async -> Bool {
    guard let client else {
      return false
    }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let simulation = try await client.simulateTaskBoardPolicyPipeline(
        request: TaskBoardPolicyPipelineSimulateRequest(document: document)
      )
      recordRequestSuccess()
      globalTaskBoardPolicySimulation = simulation
      globalTaskBoardPolicyAudit = await loadTaskBoardPolicyAudit(using: client)
      if simulation.validation.isValid {
        presentSuccessFeedback("Simulated policy")
      } else {
        presentFailureFeedback(
          simulation.validation.issues.first?.message ?? "Policy simulation found issues"
        )
      }
      return simulation.succeeded
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  @discardableResult
  public func promoteTaskBoardPolicyPipeline(revision: UInt64) async -> Bool {
    guard let client else {
      return false
    }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let response = try await client.promoteTaskBoardPolicyPipeline(
        request: TaskBoardPolicyPipelinePromoteRequest(revision: revision)
      )
      recordRequestSuccess()
      globalTaskBoardPolicyPipeline = response.document
      globalTaskBoardPolicyAudit = await loadTaskBoardPolicyAudit(using: client)
      await applyTaskBoardPolicyPipelineSupervisorOverrides(response.document)
      presentSuccessFeedback("Promoted policy")
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  nonisolated private func loadTaskBoardPolicyAudit(
    using client: any HarnessMonitorClientProtocol
  ) async -> TaskBoardPolicyPipelineAuditSummary? {
    do {
      return try await client.taskBoardPolicyPipelineAudit()
    } catch {
      let description = RefreshSnapshotErrorFormatting.describeUnderlying(error)
      HarnessMonitorLogger.store.debug(
        "task-board policy audit unavailable during refresh: \(description, privacy: .public)"
      )
      return nil
    }
  }

  private func applyTaskBoardPolicyPipelineSupervisorOverrides(
    _ document: TaskBoardPolicyPipelineDocument?
  ) async {
    guard let registry = supervisorStack?.registry else {
      return
    }
    if let document, document.mode == .enforced {
      await registry.applyOverrides(document.supervisorPolicyOverrides())
    } else {
      await registry.applyOverrides(await loadPolicyOverrides())
    }
  }
}
