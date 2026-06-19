import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas validation panel")
@MainActor
struct PolicyCanvasValidationPanelTests {
  @Test("daemon issues surface in allValidationIssues with severity classification")
  func daemonIssuesSurfaceWithSeverity() async {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.latestSimulation = makeSimulation(
      issues: [
        TaskBoardPolicyPipelineValidationIssue(
          code: "cycle",
          message: "cycle across two nodes",
          nodeIds: ["risk-score", "review-gate"]
        ),
        TaskBoardPolicyPipelineValidationIssue(
          code: "dangling_edge",
          message: "edge points at missing port",
          edgeId: "edge-intake-risk"
        ),
        TaskBoardPolicyPipelineValidationIssue(
          code: "soft_warning",
          message: "policy heuristic",
          nodeId: "risk-score"
        ),
      ]
    )
    await applyValidationPresentation(viewModel)

    let resolved = viewModel.allValidationIssues
    #expect(resolved.count >= 3)
    #expect(resolved.contains { $0.issue.code == "cycle" })
    #expect(resolved.contains { $0.issue.code == "dangling_edge" })
    #expect(resolved.contains { $0.issue.code == "soft_warning" })
    // Errors must sort above warnings.
    let firstError = resolved.first { $0.severity == .error }
    let firstWarning = resolved.first { $0.severity == .warning }
    if let firstError, let firstWarning {
      let errorIndex = resolved.firstIndex(of: firstError) ?? -1
      let warningIndex = resolved.firstIndex(of: firstWarning) ?? -1
      #expect(errorIndex < warningIndex)
    }
  }

  @Test("clicking focus on a node-scoped issue moves selection to the node")
  func focusIssueSelectsNode() async {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(nil)
    viewModel.latestSimulation = makeSimulation(
      issues: [
        TaskBoardPolicyPipelineValidationIssue(
          code: "invalid_port",
          message: "bad port",
          nodeId: "risk-score",
          port: "ghost",
          direction: "input"
        )
      ]
    )
    await applyValidationPresentation(viewModel)
    let resolved = viewModel.allValidationIssues.first!

    viewModel.focusIssue(resolved)

    #expect(viewModel.selection == .node("risk-score"))
  }

  @Test("clicking focus on an edge-scoped issue moves selection to the edge")
  func focusIssueSelectsEdge() async {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(nil)
    viewModel.latestSimulation = makeSimulation(
      issues: [
        TaskBoardPolicyPipelineValidationIssue(
          code: "dangling_edge",
          message: "edge points at missing port",
          edgeId: "edge-intake-risk"
        )
      ]
    )
    await applyValidationPresentation(viewModel)
    let resolved = viewModel.allValidationIssues.first!

    viewModel.focusIssue(resolved)

    #expect(viewModel.selection == .edge("edge-intake-risk"))
  }

  @Test("focus is a no-op when neither node nor edge resolves to anything live")
  func focusIssueGracefullyNoOps() async {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.group("group-evaluation"))
    viewModel.latestSimulation = makeSimulation(
      issues: [
        TaskBoardPolicyPipelineValidationIssue(
          code: "duplicate_id",
          message: "id collision",
          nodeId: "node-that-does-not-exist"
        )
      ]
    )
    await applyValidationPresentation(viewModel)
    let resolved = viewModel.allValidationIssues.first!

    viewModel.focusIssue(resolved)

    // No live focusSelection means focus is a no-op and selection stays as-is.
    #expect(resolved.focusSelection == nil)
    #expect(viewModel.selection == .group("group-evaluation"))
  }

  @Test("severity classification covers known daemon codes")
  func severityClassificationMatchesKnownCodes() {
    #expect(PolicyCanvasIssueSeverity.from(code: "cycle") == .error)
    #expect(PolicyCanvasIssueSeverity.from(code: "dangling_edge") == .error)
    #expect(PolicyCanvasIssueSeverity.from(code: "duplicate_id") == .error)
    #expect(PolicyCanvasIssueSeverity.from(code: "invalid_port") == .error)
    #expect(PolicyCanvasIssueSeverity.from(code: "unsupported_schema_version") == .error)
    #expect(PolicyCanvasIssueSeverity.from(code: "orphan_node") == .error)
    #expect(PolicyCanvasIssueSeverity.from(code: "unsafe_high_risk_action") == .error)
    #expect(PolicyCanvasIssueSeverity.from(code: "unknown_future_code") == .warning)
  }

  @Test("issue presentation uses actionable titles and target summaries")
  func issuePresentationUsesActionableTitlesAndTargets() async {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.latestSimulation = makeSimulation(
      issues: [
        TaskBoardPolicyPipelineValidationIssue(
          code: "cycle",
          message: "cycle across two nodes",
          nodeIds: ["risk-score", "review-gate"]
        ),
        TaskBoardPolicyPipelineValidationIssue(
          code: "dangling_edge",
          message: "edge points at missing port",
          edgeId: "edge-intake-risk"
        ),
      ]
    )
    await applyValidationPresentation(viewModel)

    let cycle = viewModel.allValidationIssues.first { $0.issue.code == "cycle" }
    let edge = viewModel.allValidationIssues.first { $0.issue.code == "dangling_edge" }

    #expect(cycle != nil)
    #expect(edge != nil)

    if let cycle {
      let cyclePresentation = viewModel.issuePresentation(for: cycle)
      #expect(cyclePresentation.title == "Break the cycle")
      #expect(cyclePresentation.targetSummary == "Steps: Review open? and Wait for checks")
    }

    if let edge {
      let edgePresentation = viewModel.issuePresentation(for: edge)
      #expect(edgePresentation.title == "Reconnect or remove this path")
      #expect(edgePresentation.targetSummary == "Path: start (Reviews Auto to Review open?)")
    }
  }

  @Test("hasIssues(forNode:) reports true when nodeId or nodeIds matches")
  func hasIssuesForNodeMatchesEitherField() async {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.latestSimulation = makeSimulation(
      issues: [
        TaskBoardPolicyPipelineValidationIssue(
          code: "duplicate_id",
          message: "collision",
          nodeId: "risk-score"
        ),
        TaskBoardPolicyPipelineValidationIssue(
          code: "cycle",
          message: "cycle",
          nodeIds: ["context-map", "promote-release"]
        ),
      ]
    )
    await applyValidationPresentation(viewModel)

    #expect(viewModel.hasIssues(forNode: "risk-score"))
    #expect(viewModel.hasIssues(forNode: "context-map"))
    #expect(viewModel.hasIssues(forNode: "promote-release"))
    #expect(!viewModel.hasIssues(forNode: "policy-source"))
  }

  @Test("hasIssues(forEdge:) reports true when edgeId matches")
  func hasIssuesForEdgeMatchesField() async {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.latestSimulation = makeSimulation(
      issues: [
        TaskBoardPolicyPipelineValidationIssue(
          code: "dangling_edge",
          message: "dead",
          edgeId: "edge-intake-risk"
        )
      ]
    )
    await applyValidationPresentation(viewModel)

    #expect(viewModel.hasIssues(forEdge: "edge-intake-risk"))
    #expect(!viewModel.hasIssues(forEdge: "edge-context-promote"))
  }

  @Test("resolvedIssues(for:) filters to the selection target")
  func resolvedIssuesFilterToSelection() async {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.latestSimulation = makeSimulation(
      issues: [
        TaskBoardPolicyPipelineValidationIssue(
          code: "invalid_port",
          message: "bad port",
          nodeId: "risk-score"
        ),
        TaskBoardPolicyPipelineValidationIssue(
          code: "duplicate_id",
          message: "duplicate node",
          nodeId: "context-map"
        ),
        TaskBoardPolicyPipelineValidationIssue(
          code: "dangling_edge",
          message: "dead edge",
          edgeId: "edge-intake-risk"
        ),
      ]
    )
    await applyValidationPresentation(viewModel)

    let nodeIssues = viewModel.resolvedIssues(for: .node("risk-score"))
    #expect(nodeIssues.count == 1)
    #expect(nodeIssues.first?.issue.code == "invalid_port")

    let edgeIssues = viewModel.resolvedIssues(for: .edge("edge-intake-risk"))
    #expect(edgeIssues.count == 1)
    #expect(edgeIssues.first?.issue.code == "dangling_edge")

    let groupIssues = viewModel.resolvedIssues(for: .group("group-evaluation"))
    #expect(groupIssues.isEmpty)
  }

  @Test("issue ids are stable across repeated allValidationIssues reads")
  func resolvedIssueIDsAreStable() async {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.latestSimulation = makeSimulation(
      issues: [
        TaskBoardPolicyPipelineValidationIssue(
          code: "cycle",
          message: "cycle",
          nodeIds: ["risk-score", "review-gate"]
        ),
        TaskBoardPolicyPipelineValidationIssue(
          code: "duplicate_id",
          message: "dup",
          nodeId: "context-map"
        ),
      ]
    )
    await applyValidationPresentation(viewModel)

    let firstPass = viewModel.allValidationIssues.map(\.id)
    let secondPass = viewModel.allValidationIssues.map(\.id)

    #expect(firstPass == secondPass)
    #expect(Set(firstPass).count == firstPass.count)
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

  private func applyValidationPresentation(_ viewModel: PolicyCanvasViewModel) async {
    let worker = PolicyCanvasValidationWorker()
    let output = await worker.compute(
      input: PolicyCanvasValidationWorkerInput(
        nodes: viewModel.nodes,
        edges: viewModel.edges,
        daemonIssues: viewModel.daemonValidationIssues
      )
    )
    viewModel.applyValidationPresentation(output)
  }
}
