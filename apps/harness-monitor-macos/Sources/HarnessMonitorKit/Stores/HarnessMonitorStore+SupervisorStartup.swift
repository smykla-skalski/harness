import Foundation
import SwiftData

extension HarnessMonitorStore {
  func performSupervisorStartup() async {
    defer { supervisorStartTask = nil }

    guard supervisorStack == nil else {
      HarnessMonitorLogger.supervisorTrace("supervisor.start skipped — already running")
      return
    }

    HarnessMonitorLogger.supervisorTrace("supervisor.start")

    let decisionStore: DecisionStore
    if let container = modelContext?.container {
      decisionStore = DecisionStore(container: container)
    } else {
      do {
        decisionStore = try DecisionStore.makeInMemory()
      } catch {
        HarnessMonitorLogger.supervisorError(
          "supervisor.start failed to create DecisionStore: \(error.localizedDescription)"
        )
        return
      }
    }

    let registry = PolicyRegistry()
    await registry.registerDefaults()
    await registry.applyOverrides(Self.loadPolicyOverrides(from: modelContext))

    let apiClient = StoreAPIClient(store: self)
    let auditWriter: any SupervisorAuditWriter
    let auditRetention: SupervisorAuditRetention?
    if let container = modelContext?.container {
      auditWriter = SwiftDataSupervisorAuditWriter(container: container)
      auditRetention = SupervisorAuditRetention(container: container)
    } else {
      auditWriter = NoOpSupervisorAuditWriter()
      auditRetention = nil
    }

    let executor = PolicyExecutor(
      api: apiClient,
      decisions: decisionStore,
      audit: auditWriter
    )

    let service = SupervisorService(
      store: self,
      registry: registry,
      executor: executor,
      clock: nil,
      interval: SupervisorPreferencesDefaults.defaultIntervalSeconds
    )
    await service.setQuietHoursWindow(SupervisorPreferencesDefaults.quietHoursWindow())

    let lifecycle = SupervisorLifecycle(
      interval: SupervisorPreferencesDefaults.defaultIntervalSeconds,
      tolerance: SupervisorPreferencesDefaults.schedulerTolerance
    )
    lifecycle.onTick = { [weak service] in
      await service?.runOneTick()
    }

    do {
      try await seedSupervisorDecisionsIfNeeded(decisionStore)
    } catch {
      HarnessMonitorLogger.supervisorWarning(
        "supervisor.seed_decisions_failed error=\(String(describing: error))"
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
      guard let self else { return }
      await self.runDecisionRelayTask(decisions: decisionStore)
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

    HarnessMonitorLogger.supervisorTrace("supervisor.started")
  }

  private func runDecisionRelayTask(decisions: DecisionStore) async {
    await refreshSupervisorDecisionSurfaces(decisions: decisions)
    for await _ in decisions.events {
      guard !Task.isCancelled else { return }
      await refreshSupervisorDecisionSurfaces(decisions: decisions)
    }
  }

  private func refreshSupervisorDecisionSurfaces(decisions: DecisionStore) async {
    let openDecisions = (try? await decisions.openDecisions()) ?? []
    var counts: [DecisionSeverity: Int] = [:]
    for decision in openDecisions {
      guard let severity = DecisionSeverity(rawValue: decision.severityRaw) else {
        continue
      }
      counts[severity, default: 0] += 1
    }
    supervisorOpenDecisions = openDecisions
    supervisorToolbarSlice.refresh(counts: counts)
    supervisorBindings.pendingDecisionsBadgeSync?(openDecisions.count)
    if let controller = supervisorBindings.notificationController {
      await controller.syncAppBadgeCount(openDecisions.count)
    }
    supervisorDecisionRefreshTick &+= 1
  }

  private func seedPendingAcpPermissionDecisionsIfNeeded(
    _ decisionStore: DecisionStore
  ) async throws {
    let payloads = acpPermissionPayloadsByDecisionID.values.sorted {
      if $0.rawBatch.createdAt != $1.rawBatch.createdAt {
        return $0.rawBatch.createdAt < $1.rawBatch.createdAt
      }
      return $0.decisionID < $1.decisionID
    }
    HarnessMonitorUITestTrace.record(
      component: "supervisor.startup",
      event: "seed-acp-decisions",
      details: ["count": String(payloads.count)]
    )
    for payload in payloads {
      try await decisionStore.upsertOpen(payload.decisionDraft)
    }
  }
}
