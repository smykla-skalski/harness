import Foundation
import HarnessMonitorPolicyCanvas
import HarnessMonitorPolicyModels
import XCTest

@testable import HarnessMonitorKit

extension PolicyCanvasStoreTests {
  func testRecoveryRetriesAfterTransientWorkspaceFailure() async throws {
    let client = RecordingHarnessClient()
    let expectedWorkspace = try await client.policyCanvasWorkspace()
    let store = await makeBootstrappedStore(client: client)
    store.taskBoardPolicyRuntimeRecoveryPending = true
    store.cacheWriteSync.policyRecoveryRetryOverride = .milliseconds(10)
    store.globalPolicyCanvasWorkspace = expectedWorkspace
    client.policyCanvasWorkspaceError = NSError(
      domain: "PolicyCanvasStoreTests",
      code: 2
    )

    let refreshed = await store.refreshPolicyPipeline()
    XCTAssertFalse(refreshed)
    XCTAssertTrue(store.taskBoardPolicyRuntimeRecoveryPending)

    client.policyCanvasWorkspaceError = nil
    let recovered = await HarnessMonitorKitTests.waitUntil(timeout: .seconds(2)) {
      !store.taskBoardPolicyRuntimeRecoveryPending
    }

    XCTAssertTrue(recovered)
    XCTAssertEqual(store.globalPolicyCanvasWorkspace, expectedWorkspace)
  }

  func testRecoveryRetrySlotSurvivesDisconnectAndStaleAccess() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.taskBoardPolicyRuntimeRecoveryPending = true
    store.cacheWriteSync.policyRecoveryRetryOverride = .milliseconds(10)
    client.policyCanvasWorkspaceError = NSError(
      domain: "PolicyCanvasStoreTests",
      code: 3
    )

    let firstRefreshSucceeded = await store.refreshPolicyPipeline()
    XCTAssertFalse(firstRefreshSucceeded)
    XCTAssertNotNil(store.cacheWriteSync.taskBoardPolicyRecoveryTask)
    store.stopGlobalStream()
    XCTAssertNil(store.cacheWriteSync.taskBoardPolicyRecoveryTask)

    let staleRefreshSucceeded = await store.refreshPolicyPipeline()
    XCTAssertFalse(staleRefreshSucceeded)
    store.taskBoardRuntimeState.connection.databaseAccessGeneration &+= 1
    let staleRetryReleased = await HarnessMonitorKitTests.waitUntil {
      store.cacheWriteSync.taskBoardPolicyRecoveryTask == nil
    }
    XCTAssertTrue(staleRetryReleased)

    let currentRefreshSucceeded = await store.refreshPolicyPipeline()
    XCTAssertFalse(currentRefreshSucceeded)
    client.policyCanvasWorkspaceError = nil
    let didRecover = await HarnessMonitorKitTests.waitUntil(timeout: .seconds(2)) {
      !store.taskBoardPolicyRuntimeRecoveryPending
    }
    XCTAssertTrue(didRecover)
  }

  func testPolicyRefreshesPublishInRequestOrder() async throws {
    let client = RecordingHarnessClient()
    let oldDocument = client.samplePolicyPipeline(canvasId: "canvas-old", title: "Old")
    let newDocument = client.samplePolicyPipeline(canvasId: "canvas-new", title: "New")
    let oldWorkspace = makePolicyWorkspace(document: oldDocument, client: client)
    let newWorkspace = makePolicyWorkspace(document: newDocument, client: client)
    let sequence = PolicyWorkspaceReadSequence(first: oldWorkspace, second: newWorkspace)
    let store = await makeBootstrappedStore(client: client)
    client.policyCanvasWorkspaceHandler = { await sequence.next() }
    client.policyPipelinesByCanvasID = [
      "canvas-old": oldDocument,
      "canvas-new": newDocument,
    ]
    client.policyAuditByCanvasID = [
      "canvas-old": client.samplePolicyPipelineAudit(for: oldDocument),
      "canvas-new": client.samplePolicyPipelineAudit(for: newDocument),
    ]

    let first = Task { @MainActor in await store.refreshPolicyPipeline() }
    await sequence.waitUntilFirstReadStarts()
    let second = Task { @MainActor in await store.refreshPolicyPipeline() }
    let queued = await HarnessMonitorKitTests.waitUntil {
      store.taskBoardRuntimeState.policyPublication.waiters.count == 1
    }
    XCTAssertTrue(queued)
    await sequence.releaseFirstRead()

    let firstResult = await first.value
    let secondResult = await second.value
    XCTAssertTrue(firstResult)
    XCTAssertTrue(secondResult)
    XCTAssertEqual(store.globalPolicyCanvasWorkspace?.activeCanvasId, "canvas-new")
    XCTAssertEqual(store.globalPolicyPipeline?.nodes.first?.title, "New")
  }

  func testCancelledPolicyRefreshDoesNotRunAfterLockWait() async throws {
    let client = RecordingHarnessClient()
    let workspace = try await client.policyCanvasWorkspace()
    let sequence = PolicyWorkspaceReadSequence(first: workspace, second: workspace)
    let store = await makeBootstrappedStore(client: client)
    client.policyCanvasWorkspaceHandler = { await sequence.next() }

    let first = Task { @MainActor in await store.refreshPolicyPipeline() }
    await sequence.waitUntilFirstReadStarts()
    let cancelled = Task { @MainActor in await store.refreshPolicyPipeline() }
    let didQueueCancelledRefresh = await HarnessMonitorKitTests.waitUntil {
      store.taskBoardRuntimeState.policyPublication.waiters.count == 1
    }
    XCTAssertTrue(didQueueCancelledRefresh)
    cancelled.cancel()
    let didRemoveCancelledRefresh = await HarnessMonitorKitTests.waitUntil {
      store.taskBoardRuntimeState.policyPublication.waiters.isEmpty
    }
    XCTAssertTrue(didRemoveCancelledRefresh)
    await sequence.releaseFirstRead()

    let firstResult = await first.value
    let cancelledResult = await cancelled.value
    let readCount = await sequence.readCount
    XCTAssertTrue(firstResult)
    XCTAssertFalse(cancelledResult)
    XCTAssertEqual(readCount, 1)
  }
}

private actor PolicyWorkspaceReadSequence {
  private let first: PolicyCanvasWorkspace
  private let second: PolicyCanvasWorkspace
  private var count = 0
  private var firstStarted = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstRelease: CheckedContinuation<Void, Never>?

  init(first: PolicyCanvasWorkspace, second: PolicyCanvasWorkspace) {
    self.first = first
    self.second = second
  }

  func next() async -> PolicyCanvasWorkspace {
    count += 1
    guard count == 1 else { return second }
    firstStarted = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { firstRelease = $0 }
    return first
  }

  func waitUntilFirstReadStarts() async {
    guard !firstStarted else { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func releaseFirstRead() {
    firstRelease?.resume()
    firstRelease = nil
  }

  var readCount: Int { count }
}

private func makePolicyWorkspace(
  document: PolicyPipelineDocument,
  client: RecordingHarnessClient
) -> PolicyCanvasWorkspace {
  let canvasId =
    document.policyTraceIds.first?.replacingOccurrences(of: "trace-", with: "")
    ?? "canvas"
  return PolicyCanvasWorkspace(
    schemaVersion: 1,
    activeCanvasId: canvasId,
    canvases: [
      client.policyCanvasSummary(
        canvasId: canvasId,
        title: document.nodes.first?.title ?? "Policy",
        document: document,
        latestSimulation: nil
      )
    ]
  )
}
