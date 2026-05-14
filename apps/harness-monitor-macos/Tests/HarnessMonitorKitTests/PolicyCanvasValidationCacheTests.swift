import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

/// Covers the severity-map cache that sits between `allValidationIssues`
/// and the hot-path node/edge layer bodies. Two contracts matter:
///   1. Repeated reads with no intervening mutation must reuse the
///      cached storage — a graph drag would otherwise rebuild the maps
///      twice per render on a 100-node canvas.
///   2. Every mutation that can change validator output must bump the
///      invalidation generation so the next read rebuilds from a fresh
///      `allValidationIssues` walk.
@Suite("Policy canvas validation cache")
@MainActor
struct PolicyCanvasValidationCacheTests {
  @Test("repeated reads reuse the cached storage without bumping generation")
  func repeatedReadsReuseCache() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.latestSimulation = makeSimulation(
      issues: [
        TaskBoardPolicyPipelineValidationIssue(
          code: "cycle",
          message: "cycle",
          nodeIds: ["risk-score", "review-gate"]
        )
      ]
    )

    let initialGeneration = viewModel.validationInvalidationGeneration
    // First read populates the storage slot from nil; subsequent reads
    // must token-match and return the cached maps without rebuilding.
    #expect(viewModel.validationCacheStorage == nil)
    let first = viewModel.cachedSeverityMaps()
    let primedToken = viewModel.validationCacheStorage?.token
    #expect(primedToken != nil)
    let second = viewModel.cachedSeverityMaps()

    #expect(first.nodes == second.nodes)
    #expect(first.edges == second.edges)
    #expect(viewModel.validationCacheStorage?.token == primedToken)
    #expect(viewModel.validationInvalidationGeneration == initialGeneration)
  }

  @Test("createNode invalidates the cache so the next read rebuilds")
  func createNodeBumpsGeneration() {
    let viewModel = PolicyCanvasViewModel.sample()
    _ = viewModel.cachedSeverityMaps()
    let before = viewModel.validationInvalidationGeneration

    viewModel.createNode(kind: .condition, at: CGPoint(x: 100, y: 100))

    #expect(viewModel.validationInvalidationGeneration == before + 1)
  }

  @Test("endNodeDrag invalidates the cache once per gesture, not per tick")
  func endNodeDragBumpsGenerationExactlyOnce() {
    let viewModel = PolicyCanvasViewModel.sample()
    _ = viewModel.cachedSeverityMaps()
    let before = viewModel.validationInvalidationGeneration

    viewModel.dragNode("risk-score", translation: CGSize(width: 12, height: 12))
    viewModel.dragNode("risk-score", translation: CGSize(width: 24, height: 24))
    // Drag ticks themselves do not bump generation, only the end-of-gesture.
    #expect(viewModel.validationInvalidationGeneration == before)

    viewModel.endNodeDrag("risk-score", translation: CGSize(width: 24, height: 24))

    #expect(viewModel.validationInvalidationGeneration == before + 1)
  }

  @Test("connectDroppedPortPayloads invalidates the cache on a fresh edge")
  func connectInvalidatesCache() {
    let viewModel = PolicyCanvasViewModel.sample()
    _ = viewModel.cachedSeverityMaps()
    let before = viewModel.validationInvalidationGeneration

    let created = viewModel.connectDroppedPortPayloads(
      [viewModel.portDragPayload(nodeID: "policy-source", portID: "output-event")],
      targetNodeID: "review-gate",
      targetPortID: "input-policy"
    )

    #expect(created)
    #expect(viewModel.validationInvalidationGeneration == before + 1)
  }

  @Test("deleting a node invalidates the cache")
  func deletionInvalidatesCache() {
    let viewModel = PolicyCanvasViewModel.sample()
    _ = viewModel.cachedSeverityMaps()
    let before = viewModel.validationInvalidationGeneration

    viewModel.select(.node("policy-source"))
    let request = viewModel.deleteSelectedComponent()
    if let request {
      viewModel.confirmDelete(request)
    }

    #expect(viewModel.validationInvalidationGeneration > before)
  }

  @Test("installing a new simulation rebuilds the cache with fresh severities")
  func simulationInstallRebuildsMaps() {
    let viewModel = PolicyCanvasViewModel.sample()
    // Prime the cache with no issues.
    let initialMaps = viewModel.cachedSeverityMaps()
    #expect(initialMaps.nodes.isEmpty)
    #expect(initialMaps.edges.isEmpty)

    viewModel.latestSimulation = makeSimulation(
      issues: [
        TaskBoardPolicyPipelineValidationIssue(
          code: "dangling_edge",
          message: "edge points at missing port",
          edgeId: "edge-intake-risk"
        ),
        TaskBoardPolicyPipelineValidationIssue(
          code: "duplicate_id",
          message: "id collision",
          nodeId: "risk-score"
        ),
      ]
    )
    // Simulation install is not currently routed through invalidate —
    // bump explicitly so the cache token compare actually misses on the
    // next read. The token includes simulation revision + issue count,
    // so this read would also miss on the count delta even without the
    // explicit bump, but we keep the assertion narrow.
    viewModel.invalidateValidationCache()

    let rebuilt = viewModel.cachedSeverityMaps()
    #expect(rebuilt.edges["edge-intake-risk"] == .error)
    #expect(rebuilt.nodes["risk-score"] == .error)
  }

  @Test("nodeSeverityMap reader returns the same values across two reads")
  func nodeSeverityMapStableAcrossReads() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.latestSimulation = makeSimulation(
      issues: [
        TaskBoardPolicyPipelineValidationIssue(
          code: "cycle",
          message: "cycle",
          nodeIds: ["risk-score", "review-gate"]
        )
      ]
    )
    viewModel.invalidateValidationCache()

    let first = viewModel.nodeSeverityMap
    let second = viewModel.nodeSeverityMap

    #expect(first == second)
    #expect(first["risk-score"] == .error)
    #expect(first["review-gate"] == .error)
  }

  @Test("token matches across two reads with no mutation, differs after invalidate")
  func tokenChangesOnInvalidate() {
    let viewModel = PolicyCanvasViewModel.sample()
    let firstToken = viewModel.validationCacheToken()
    let secondToken = viewModel.validationCacheToken()
    #expect(firstToken == secondToken)

    viewModel.invalidateValidationCache()
    let thirdToken = viewModel.validationCacheToken()
    #expect(thirdToken != secondToken)
  }

  // MARK: - Helpers

  private func makeSimulation(
    issues: [TaskBoardPolicyPipelineValidationIssue]
  ) -> TaskBoardPolicyPipelineSimulationResult {
    TaskBoardPolicyPipelineSimulationResult(
      revision: 1,
      traceId: "trace-test",
      simulatedAt: "2026-05-14T00:00:00Z",
      succeeded: issues.isEmpty,
      validation: TaskBoardPolicyPipelineValidation(
        isValid: issues.isEmpty,
        issues: issues
      )
    )
  }
}
