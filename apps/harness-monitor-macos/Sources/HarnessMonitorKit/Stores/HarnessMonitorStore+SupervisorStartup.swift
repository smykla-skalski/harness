import Foundation
import SwiftData

extension HarnessMonitorStore {
  func performSupervisorStartup() async {
    defer {
      if supervisorStack == nil {
        setSupervisorRuntimeState(.stopped)
      }
      supervisorStartTask = nil
    }

    guard supervisorStack == nil else {
      setSupervisorRuntimeState(.running)
      HarnessMonitorLogger.supervisorTrace("supervisor.start skipped — already running")
      return
    }

    HarnessMonitorLogger.supervisorTrace("supervisor.start")

    let supervisorClock = WallClock()
    let decisionStore: DecisionStore
    do {
      decisionStore = try makeSupervisorDecisionStore(clock: supervisorClock)
    } catch {
      HarnessMonitorLogger.supervisorError(
        "supervisor.start failed to create DecisionStore: \(error.localizedDescription)"
      )
      return
    }

    let registry = await makeSupervisorRegistry()

    let apiClient = StoreAPIClient(store: self)
    let (auditWriter, auditRetention) = makeSupervisorAuditSupport()

    let executor = PolicyExecutor(
      api: apiClient,
      decisions: decisionStore,
      audit: auditWriter,
      clock: supervisorClock
    )

    let service = SupervisorService(
      store: self,
      registry: registry,
      executor: executor,
      clock: supervisorClock,
      interval: SupervisorSettingsDefaults.defaultIntervalSeconds
    )
    await service.setQuietHoursWindow(SupervisorSettingsDefaults.quietHoursWindow())

    let lifecycle = SupervisorLifecycle(
      interval: SupervisorSettingsDefaults.defaultIntervalSeconds,
      tolerance: SupervisorSettingsDefaults.schedulerTolerance
    )

    do {
      try await seedSupervisorDecisionsIfNeeded(decisionStore)
    } catch {
      HarnessMonitorLogger.supervisorWarning(
        "supervisor.seed_decisions_failed error=\(String(describing: error))"
      )
    }
    do {
      try await repairRecoveredDaemonDisconnectDecision(decisionStore)
    } catch {
      HarnessMonitorLogger.supervisorWarning(
        "supervisor.repair_daemon_disconnect_decisions_failed error=\(String(describing: error))"
      )
    }
    reconcileAcpPermissionDecisions()
    do {
      try await seedPendingAcpPermissionDecisionsIfNeeded(decisionStore)
    } catch {
      HarnessMonitorLogger.supervisorWarning(
        "supervisor.seed_acp_decisions_failed error=\(String(describing: error))"
      )
    }

    let relayTask = Task { @MainActor [weak self] in
      await self?.refreshSupervisorDecisionSurfaces(decisions: decisionStore)
      for await _ in decisionStore.events {
        guard !Task.isCancelled else { return }
        await self?.refreshSupervisorDecisionSurfaces(decisions: decisionStore)
      }
    }

    let stack = SupervisorStack(
      decisionStore: decisionStore,
      registry: registry,
      executor: executor,
      service: service,
      lifecycle: lifecycle,
      auditRetention: auditRetention,
      relayTask: relayTask
    )
    supervisorStack = stack

    await service.start()
    lifecycle.startBackgroundActivity()
    auditRetention?.startBackgroundCompaction()

    if supervisorRuntimeState != .stopping {
      setSupervisorRuntimeState(.running)
    }
    HarnessMonitorLogger.supervisorTrace("supervisor.started")
  }

  private func makeSupervisorDecisionStore(clock: WallClock) throws -> DecisionStore {
    if let container = modelContext?.container {
      return DecisionStore(container: container, now: { clock.now() })
    }
    return try DecisionStore.makeInMemory(now: { clock.now() })
  }

  private func makeSupervisorRegistry() async -> PolicyRegistry {
    let registry = PolicyRegistry()
    await registry.registerDefaults()
    await registry.applyOverrides(await loadPolicyOverrides())
    return registry
  }

  private func makeSupervisorAuditSupport() -> (
    auditWriter: any SupervisorAuditWriter,
    auditRetention: SupervisorAuditRetention?
  ) {
    if let container = modelContext?.container {
      return (
        SwiftDataSupervisorAuditWriter(container: container),
        SupervisorAuditRetention(container: container)
      )
    }
    return (NoOpSupervisorAuditWriter(), nil)
  }

  private func refreshSupervisorDecisionSurfaces(decisions: DecisionStore) async {
    let snapshot =
      (try? await decisions.openSupervisorSurfaceSnapshot(
        includeDaemonDisconnect: connectionState.isSupervisorDisconnectedState
      ))
      ?? .empty
    supervisorOpenDecisions = snapshot.decisions
    supervisorOpenDecisionsByID = snapshot.decisionsByID
    supervisorOpenDecisionPresentationItems = snapshot.presentationItems
    supervisorOpenDecisionPresentationItemsBySession = snapshot.presentationItemsBySession
    supervisorOpenDecisionSearchProjections = snapshot.searchProjections
    supervisorOpenDecisionSearchProjectionsBySession = snapshot.searchProjectionsBySession
    supervisorOpenDecisionIDsBySession = snapshot.decisionIDsBySession
    supervisorToolbarSlice.refresh(counts: snapshot.countsBySeverity)
    supervisorBindings.pendingDecisionsBadgeSync?(snapshot.decisions.count)
    supervisorBindings.pendingDecisionsStatusSync?(
      supervisorToolbarSlice.count,
      supervisorToolbarSlice.maxSeverity
    )
    if let controller = supervisorBindings.notificationController {
      await controller.syncAppBadgeCount(snapshot.decisions.count)
    }
    supervisorDecisionRefreshTick &+= 1
  }

  private func seedPendingAcpPermissionDecisionsIfNeeded(
    _ decisionStore: DecisionStore
  ) async throws {
    let payloads = await acpRuntimeWorker.sortedPermissionDecisionPayloads(
      Array(acpPermissionPayloadsByDecisionID.values)
    )
    HarnessMonitorUITestTrace.record(
      component: "supervisor.startup",
      event: "seed-acp-decisions",
      details: ["count": String(payloads.count)]
    )
    for payload in payloads {
      try await decisionStore.upsertOpen(payload.decisionDraft)
    }
  }

  private func repairRecoveredDaemonDisconnectDecision(
    _ decisionStore: DecisionStore
  ) async throws {
    guard !connectionState.isSupervisorDisconnectedState else {
      return
    }
    guard try await dismissActiveDaemonDisconnectDecision(decisionStore) else {
      return
    }
    HarnessMonitorLogger.supervisorTrace(
      "supervisor.repaired_daemon_disconnect_decision id=\(DaemonDisconnectRule.activeDecisionID)"
    )
  }
}
