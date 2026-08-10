import HarnessMonitorPolicyModels
import SwiftData
import XCTest

@testable import HarnessMonitorKit

final class PolicyRegistryTests: XCTestCase {
  func test_registerAndListRulesPreservesInsertionOrder() async {
    let registry = PolicyRegistry()
    await registry.register(StubRule(id: "alpha"))
    await registry.register(StubRule(id: "bravo"))
    await registry.register(StubRule(id: "charlie"))

    let ids = await registry.allRules.map(\.id)
    XCTAssertEqual(ids, ["alpha", "bravo", "charlie"])
  }

  func test_parameterOverrideAppliedFromConfigRow() async {
    let registry = PolicyRegistry()
    await registry.register(StubRule(id: "stub"))
    await registry.applyOverrides([
      PolicyConfigOverride(
        ruleID: "stub",
        enabled: true,
        defaultBehavior: .aggressive,
        parameters: ["threshold": "120"]
      )
    ])

    let params = await registry.parameters(forRule: "stub")
    XCTAssertEqual(params.int("threshold", default: 60), 120)
  }

  func test_parametersForUnknownRuleFallsBackToDefault() async {
    let registry = PolicyRegistry()
    let params = await registry.parameters(forRule: "missing")
    XCTAssertEqual(params.int("threshold", default: 42), 42)
  }

  func test_applyOverridesReplacesPriorOverrideForSameRule() async {
    let registry = PolicyRegistry()
    await registry.register(StubRule(id: "stub"))
    await registry.applyOverrides([
      PolicyConfigOverride(
        ruleID: "stub",
        enabled: true,
        defaultBehavior: .aggressive,
        parameters: ["threshold": "60"]
      )
    ])
    await registry.applyOverrides([
      PolicyConfigOverride(
        ruleID: "stub",
        enabled: false,
        defaultBehavior: .cautious,
        parameters: ["threshold": "180"]
      )
    ])

    let params = await registry.parameters(forRule: "stub")
    XCTAssertEqual(params.int("threshold", default: 0), 180)
    let enabled = await registry.isEnabled(ruleID: "stub")
    XCTAssertFalse(enabled)
    let behavior = await registry.defaultBehavior(forRule: "stub")
    XCTAssertEqual(behavior, .cautious)
  }

  func test_applyOverridesWithDuplicateRuleIDsUsesLastOverride() async {
    let registry = PolicyRegistry()
    await registry.applyOverrides([
      PolicyConfigOverride(
        ruleID: "stub",
        enabled: true,
        defaultBehavior: .aggressive,
        parameters: ["threshold": "60"]
      ),
      PolicyConfigOverride(
        ruleID: "stub",
        enabled: false,
        defaultBehavior: .cautious,
        parameters: ["threshold": "240"]
      ),
    ])

    let params = await registry.parameters(forRule: "stub")
    XCTAssertEqual(params.int("threshold", default: 0), 240)
    let enabled = await registry.isEnabled(ruleID: "stub")
    XCTAssertFalse(enabled)
  }

  func test_applyOverridesWithEmptyListClearsExistingOverride() async {
    let registry = PolicyRegistry()
    await registry.register(StubRule(id: "stub"))
    await registry.applyOverrides([
      PolicyConfigOverride(
        ruleID: "stub",
        enabled: false,
        defaultBehavior: .aggressive,
        parameters: ["threshold": "180"]
      )
    ])

    await registry.applyOverrides([])

    let params = await registry.parameters(forRule: "stub")
    XCTAssertEqual(params.int("threshold", default: 42), 42)
    let enabled = await registry.isEnabled(ruleID: "stub")
    XCTAssertTrue(enabled)
    let behavior = await registry.defaultBehavior(forRule: "stub")
    XCTAssertEqual(behavior, .cautious)
  }

  func test_staleTaskBoardOverrideGenerationCannotReplaceCurrentPolicy() async {
    let registry = PolicyRegistry()
    await registry.applyOverrides([
      PolicyConfigOverride(
        ruleID: "database-a",
        enabled: true,
        defaultBehavior: .aggressive,
        parameters: [:]
      )
    ])
    await registry.advanceOverrideSourceGeneration(to: 2)

    let applied = await registry.applyOverrides(
      [
        PolicyConfigOverride(
          ruleID: "stub",
          enabled: true,
          defaultBehavior: .aggressive,
          parameters: [:]
        )
      ],
      sourceGeneration: 1
    )

    XCTAssertFalse(applied)
    let overrides = await registry.currentOverrides()
    XCTAssertTrue(overrides.isEmpty)
  }

  @MainActor
  func test_settingsRefreshUsesCurrentTaskBoardPolicyGeneration() async throws {
    let container = try HarnessMonitorModelContainer.preview()
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      modelContainer: container
    )
    await store.startSupervisor()
    let stack = try XCTUnwrap(store.supervisorStack)
    let repository = try XCTUnwrap(store.supervisorPolicyConfigRepository)
    store.taskBoardRuntimeState.connection.databaseAccessGeneration = 1
    await stack.registry.advanceOverrideSourceGeneration(to: 1)
    try await repository.save(
      PolicyConfigRowSnapshot(
        ruleID: "unassigned-task",
        enabled: false,
        defaultBehaviorRaw: RuleDefaultBehavior.cautious.rawValue,
        parametersJSON: "{}"
      )
    )

    await store.refreshSupervisorPolicyOverrides()

    let isEnabled = await stack.registry.isEnabled(ruleID: "unassigned-task")
    XCTAssertFalse(isEnabled)
    await store.stopSupervisor()
  }

  @MainActor
  func test_taskBoardPolicyRecoverySuppressesSupervisorAutoActions() async throws {
    let container = try HarnessMonitorModelContainer.preview()
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      modelContainer: container
    )
    await store.startSupervisor()
    store.taskBoardPolicyRuntimeRecoveryPending = true
    await store.supervisorStack?.service.setPolicyRecoverySuppressed(true)

    let isSuppressed = await store.isSupervisorAutoActionSuppressedForTesting(at: .now)

    XCTAssertTrue(isSuppressed)
    await store.stopSupervisor()
  }

  @MainActor
  func test_settingsRefreshRetriesAcrossTaskBoardGenerationChange() async throws {
    let container = try HarnessMonitorModelContainer.preview()
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      modelContainer: container
    )
    await store.startSupervisor()
    let stack = try XCTUnwrap(store.supervisorStack)
    let repository = try XCTUnwrap(store.supervisorPolicyConfigRepository)
    let gate = SupervisorPolicyOverrideRefreshGate()
    store.supervisorBindings.policyOverrideRefreshGate = {
      await gate.waitOnFirstRefresh()
    }
    try await repository.save(
      PolicyConfigRowSnapshot(
        ruleID: "unassigned-task",
        enabled: false,
        defaultBehaviorRaw: RuleDefaultBehavior.cautious.rawValue,
        parametersJSON: "{}"
      )
    )
    let refresh = Task {
      await store.refreshSupervisorPolicyOverrides()
    }
    await gate.waitUntilBlocked()
    store.taskBoardRuntimeState.connection.databaseAccessGeneration = 1
    await stack.registry.advanceOverrideSourceGeneration(to: 1)

    await gate.releaseRefresh()
    await refresh.value

    let isEnabled = await stack.registry.isEnabled(ruleID: "unassigned-task")
    XCTAssertFalse(isEnabled)
    await store.stopSupervisor()
  }

  @MainActor
  func test_enforcedPolicyPublishesAfterQueuedSettingsRefresh() async throws {
    let client = RecordingHarnessClient()
    let container = try HarnessMonitorModelContainer.preview()
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client),
      modelContainer: container
    )
    await store.bootstrap()
    await store.startSupervisor()
    let stack = try XCTUnwrap(store.supervisorStack)
    let repository = try XCTUnwrap(store.supervisorPolicyConfigRepository)
    try await repository.save(
      PolicyConfigRowSnapshot(
        ruleID: "unassigned-task",
        enabled: false,
        defaultBehaviorRaw: RuleDefaultBehavior.cautious.rawValue,
        parametersJSON: "{}"
      )
    )
    store.globalPolicyCanvasWorkspace = nil
    store.globalPolicyPipeline = nil
    let gate = LegacyContainmentVoidGate()
    store.supervisorBindings.policyOverrideRefreshGate = { await gate.wait() }
    let settingsRefresh = Task { @MainActor in
      await store.refreshSupervisorPolicyOverrides()
    }
    let didEnterGate = await HarnessMonitorKitTests.waitUntil { await gate.hasEntered }
    XCTAssertTrue(didEnterGate)

    let document = PolicyPipelineDocument(
      revision: 2,
      mode: .enforced,
      nodes: [
        PolicyPipelineNode(
          id: PolicyGraphNodeId("unassigned-task"),
          title: "Allow unassigned task",
          kind: .supervisorRule(decision: .allow, reasonCodes: [])
        )
      ],
      edges: [],
      groups: []
    )
    let canvasId = "canvas-enforced"
    client.policyPipelinesByCanvasID = [canvasId: document]
    client.policyAuditByCanvasID = [canvasId: client.samplePolicyPipelineAudit(for: document)]
    client.policyCanvasWorkspaceStorage = PolicyCanvasWorkspace(
      schemaVersion: 1,
      activeCanvasId: canvasId,
      canvases: [
        client.policyCanvasSummary(
          canvasId: canvasId,
          title: "Enforced",
          document: document,
          latestSimulation: nil
        )
      ]
    )
    let policyRefresh = Task { @MainActor in await store.refreshPolicyPipeline() }
    let didQueuePolicyRefresh = await HarnessMonitorKitTests.waitUntil {
      store.taskBoardRuntimeState.policyPublication.waiters.count == 1
    }
    XCTAssertTrue(didQueuePolicyRefresh)

    await gate.release()
    await settingsRefresh.value
    let didRefreshPolicy = await policyRefresh.value
    XCTAssertTrue(didRefreshPolicy)

    let isEnabled = await stack.registry.isEnabled(ruleID: "unassigned-task")
    XCTAssertTrue(isEnabled)
    await store.stopSupervisor()
  }

  func test_isEnabledDefaultsToTrueWhenNoOverride() async {
    let registry = PolicyRegistry()
    await registry.register(StubRule(id: "stub"))
    let enabled = await registry.isEnabled(ruleID: "stub")
    XCTAssertTrue(enabled)
  }

  func test_registerObserverAddsToObserverList() async {
    let registry = PolicyRegistry()
    await registry.registerObserver(StubObserver(tag: "first"))
    await registry.registerObserver(StubObserver(tag: "second"))

    let observers = await registry.observerList
    let tags = observers.compactMap { ($0 as? StubObserver)?.tag }
    XCTAssertEqual(tags, ["first", "second"])
  }
}

private actor SupervisorPolicyOverrideRefreshGate {
  private var callCount = 0
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  private var arrivalContinuations: [CheckedContinuation<Void, Never>] = []

  func waitOnFirstRefresh() async {
    callCount += 1
    guard callCount == 1 else { return }
    let arrivals = arrivalContinuations
    arrivalContinuations.removeAll()
    for arrival in arrivals {
      arrival.resume()
    }
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilBlocked() async {
    guard callCount == 0 else { return }
    await withCheckedContinuation { continuation in
      arrivalContinuations.append(continuation)
    }
  }

  func releaseRefresh() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

// MARK: - Fixtures

private struct StubRule: PolicyRule {
  let id: String
  var name: String { id.capitalized }
  let version: Int = 1
  let parameters = PolicyParameterSchema(fields: [])

  func defaultBehavior(for actionKey: String) -> RuleDefaultBehavior { .cautious }

  func evaluate(
    snapshot: SessionsSnapshot,
    context: PolicyContext
  ) async -> [SupervisorAction] { [] }
}

private struct StubObserver: PolicyObserver {
  let tag: String
}
