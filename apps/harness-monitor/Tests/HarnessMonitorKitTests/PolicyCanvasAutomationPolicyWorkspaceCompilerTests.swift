import Foundation
import HarnessMonitorKit
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas automation policy workspace compiler")
@MainActor
struct PolicyCanvasAutomationPolicyWorkspaceCompilerTests {
  @Test("workspace compilation includes inactive enforced canvas documents")
  func workspaceCompilationIncludesInactiveEnforcedCanvasDocuments() throws {
    let defaultDocument = TaskBoardPolicyPipelineDocument(
      revision: 1,
      mode: .draft,
      nodes: [],
      edges: [],
      groups: []
    )
    let pastedPRDocument = policyCanvasPastedPRDryRunDocument()
    let workspace = TaskBoardPolicyCanvasWorkspace(
      schemaVersion: 1,
      activeCanvasId: "default-canvas",
      canvases: [
        policyCanvasSummary(
          canvasId: "default-canvas",
          title: "Default",
          document: defaultDocument
        ),
        policyCanvasSummary(
          canvasId: "pasted-pr-canvas",
          title: "Pasted PR approvals (dry run)",
          document: pastedPRDocument
        ),
      ]
    )

    let compilation = PolicyCanvasAutomationPolicyCompiler.compileEnforcedCanvases(
      workspace: workspace,
      activeDocument: defaultDocument
    )
    let policy = try #require(compilation.policies.first)

    #expect(compilation.policies.count == 1)
    #expect(policy.eventSource == .manualReviewTextPaste)
    #expect(policy.isDryRun)
    #expect(policy.actions.contains(.extractGitHubPullRequests))
    #expect(policy.actions.contains(.previewReviewApprovals))
    #expect(policy.actions.contains(.promptReviewApprovals))
  }
}

func policyCanvasPastedPRDryRunDocument() -> TaskBoardPolicyPipelineDocument {
  TaskBoardPolicyPipelineDocument(
    revision: 1,
    mode: .enforced,
    nodes: [
      policyCanvasPipelineNode(
        id: "automation:review-text-paste:source",
        title: "Review Text Paste",
        kind: TaskBoardPolicyPipelineNodeKind(
          kind: "action_step",
          actionId: "automation.review_text_paste"
        ),
        automation: .canvasDefault(source: .manualReviewTextPaste),
        inputs: [],
        outputs: ["default"]
      ),
      policyCanvasPipelineNode(
        id: "automation:review-text-paste:dry-run",
        title: "Dry-run gate",
        kind: TaskBoardPolicyPipelineNodeKind(kind: "dry_run_gate"),
        inputs: ["in"],
        outputs: []
      ),
    ],
    edges: [
      TaskBoardPolicyPipelineEdge(
        id: "edge:review-text-paste:dry-run",
        fromNodeId: "automation:review-text-paste:source",
        fromPort: "default",
        toNodeId: "automation:review-text-paste:dry-run",
        toPort: "in"
      )
    ],
    groups: []
  )
}

private func policyCanvasSummary(
  canvasId: String,
  title: String,
  document: TaskBoardPolicyPipelineDocument
) -> TaskBoardPolicyCanvasSummary {
  TaskBoardPolicyCanvasSummary(
    canvasId: canvasId,
    title: title,
    revision: document.revision,
    mode: document.mode,
    document: document,
    nodeCount: document.nodes.count,
    edgeCount: document.edges.count,
    groupCount: document.groups.count,
    updatedAt: "2026-05-30T00:00:00Z"
  )
}

private func policyCanvasPipelineNode(
  id: String,
  title: String,
  kind: TaskBoardPolicyPipelineNodeKind,
  automation: TaskBoardPolicyPipelineAutomationBinding? = nil,
  inputs: [String],
  outputs: [String]
) -> TaskBoardPolicyPipelineNode {
  TaskBoardPolicyPipelineNode(
    id: id,
    title: title,
    kind: kind,
    automation: automation,
    inputs: inputs.map { TaskBoardPolicyPipelinePort(id: $0, title: $0) },
    outputs: outputs.map { TaskBoardPolicyPipelinePort(id: $0, title: $0) }
  )
}
