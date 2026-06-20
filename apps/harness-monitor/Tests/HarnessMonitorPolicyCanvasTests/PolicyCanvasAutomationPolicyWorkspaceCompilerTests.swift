import Foundation
import HarnessMonitorKit
import HarnessMonitorPolicyModels
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas automation policy workspace compiler")
@MainActor
struct PolicyCanvasAutomationPolicyWorkspaceCompilerTests {
  @Test("workspace decoding accepts legacy review extraction config")
  func workspaceDecodingAcceptsLegacyReviewExtractionConfig() throws {
    let data =
      """
      {
        "schema_version": 1,
        "active_canvas_id": "default-canvas",
        "global_policy_enforcement_enabled": true,
        "canvases": [
          {
            "canvas_id": "default-canvas",
            "title": "Default",
            "revision": 1,
            "mode": "draft",
            "node_count": 0,
            "edge_count": 0,
            "group_count": 0,
            "updated_at": "2026-06-02T12:00:00Z",
            "document": {
              "schema_version": 2,
              "revision": 1,
              "mode": "draft",
              "nodes": [],
              "edges": [],
              "groups": [],
              "layout": { "nodes": [] },
              "policy_trace_ids": []
            }
          },
          {
            "canvas_id": "pasted-pr-approvals",
            "title": "Pasted PR approvals",
            "revision": 7,
            "mode": "draft",
            "node_count": 0,
            "edge_count": 0,
            "group_count": 0,
            "updated_at": "2026-06-02T12:00:00Z",
            "document": {
              "schema_version": 2,
              "revision": 7,
              "mode": "draft",
              "nodes": [],
              "edges": [],
              "groups": [],
              "layout": { "nodes": [] },
              "policy_trace_ids": []
            }
          },
          {
            "canvas_id": "pr-screenshot-extraction",
            "title": "PR screenshot extraction",
            "revision": 1,
            "mode": "enforced",
            "node_count": 1,
            "edge_count": 0,
            "group_count": 0,
            "updated_at": "2026-06-02T12:00:00Z",
            "document": {
              "schema_version": 2,
              "revision": 1,
              "mode": "enforced",
              "nodes": [
                {
                  "id": "automation:review-screenshot:source",
                  "label": "Review Screenshot Paste",
                  "kind": { "kind": "action_step", "action_id": "review_screenshot_paste" },
                  "automation": {
                    "is_enabled": true,
                    "event_source": "reviewScreenshotPaste",
                    "content_kinds": ["image"],
                    "preprocessors": [
                      "dedupeByFingerprint",
                      "normalizeGitHubPullRequestLinks",
                      "dedupePullRequests"
                    ],
                    "actions": [
                      "ocrImage",
                      "extractGitHubPullRequests",
                      "resolveReviewPullRequests",
                      "copyReviewPullRequestList",
                      "previewReviewApprovals"
                    ],
                    "postprocessors": ["auditEvent"],
                    "source_app_mode": "allExceptDenied",
                    "review_pull_request_extraction": {
                      "repository_mode": "allConfiguredRepos",
                      "number_memory_enabled": true,
                      "result_scope": "all",
                      "failure_signal_mode": "liveOrVisual",
                      "output_format": "newlineGitHubURLs",
                      "auto_copy": true,
                      "show_sheet": true
                    }
                  },
                  "input_ports": [],
                  "output_ports": ["default"]
                }
              ],
              "edges": [],
              "groups": [],
              "layout": { "nodes": [] },
              "policy_trace_ids": []
            }
          }
        ]
      }
      """.data(using: .utf8)!

    let workspace = try JSONDecoder().decode(TaskBoardPolicyCanvasWorkspace.self, from: data)
    let extraction = try #require(
      workspace.canvases[2].document?.nodes[0].automation?.reviewPullRequestExtraction
    )

    #expect(
      workspace.canvases.map(\.title) == [
        "Default",
        "Pasted PR approvals",
        "PR screenshot extraction",
      ])
    #expect(extraction.policyRepositories == [])
  }

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

  @Test("workspace compilation includes enforced review screenshot extraction canvas")
  func workspaceCompilationIncludesReviewScreenshotExtractionCanvas() throws {
    let defaultDocument = TaskBoardPolicyPipelineDocument(
      revision: 1,
      mode: .draft,
      nodes: [],
      edges: [],
      groups: []
    )
    let screenshotDocument = policyCanvasReviewScreenshotExtractionDocument()
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
          canvasId: "review-screenshot-canvas",
          title: "PR screenshot extraction",
          document: screenshotDocument
        ),
      ]
    )

    let compilation = PolicyCanvasAutomationPolicyCompiler.compileEnforcedCanvases(
      workspace: workspace,
      activeDocument: defaultDocument
    )
    let policy = try #require(compilation.policies.first)

    #expect(compilation.policies.count == 1)
    #expect(policy.eventSource == .reviewScreenshotPaste)
    #expect(policy.actions.contains(.ocrImage))
    #expect(policy.actions.contains(.resolveReviewPullRequests))
    #expect(policy.actions.contains(.copyExtractedGitHubPullRequestURLs))
    #expect(!policy.actions.contains(.copyReviewPullRequestList))
    #expect(policy.ocrConfiguration == AutomationPolicyOCRConfiguration())
    #expect(policy.reviewPullRequestExtraction == ReviewPullRequestExtractionConfiguration())
  }

  @Test("workspace compilation includes enforced manual OCR paste canvas")
  func workspaceCompilationIncludesManualOCRPasteCanvas() throws {
    let defaultDocument = TaskBoardPolicyPipelineDocument(
      revision: 1,
      mode: .draft,
      nodes: [],
      edges: [],
      groups: []
    )
    let manualOCRDocument = policyCanvasManualOCRPasteDocument()
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
          canvasId: "manual-ocr-canvas",
          title: "Manual OCR Paste",
          document: manualOCRDocument
        ),
      ]
    )

    let compilation = PolicyCanvasAutomationPolicyCompiler.compileEnforcedCanvases(
      workspace: workspace,
      activeDocument: defaultDocument
    )
    let policy = try #require(compilation.policies.first)

    #expect(compilation.policies.count == 1)
    #expect(policy.eventSource == .manualOCRPaste)
    #expect(
      policy.actions == [
        .ocrImage,
        .openDashboardDebugging,
        .rememberRecentScan,
        .showFeedback,
        .recordMetadata,
      ])
    #expect(policy.executionPlan?.orderedActions == policy.actions)
    #expect(policy.executionPlan?.fanOuts.count == 1)
    #expect(policy.executionPlan?.fanOuts.first?.payload == .text)
  }

  @Test("workspace compilation uses live document when the active document is draft")
  func workspaceCompilationUsesLiveDocumentWhenActiveDocumentIsDraft() throws {
    let draftDocument = TaskBoardPolicyPipelineDocument(
      revision: 2,
      mode: .draft,
      nodes: [],
      edges: [],
      groups: []
    )
    let workspace = TaskBoardPolicyCanvasWorkspace(
      schemaVersion: 1,
      activeCanvasId: "manual-ocr-canvas",
      canvases: [
        policyCanvasSummary(
          canvasId: "manual-ocr-canvas",
          title: "Manual OCR Paste",
          document: draftDocument,
          liveDocument: policyCanvasManualOCRPasteDocument()
        )
      ]
    )

    let compilation = PolicyCanvasAutomationPolicyCompiler.compileEnforcedCanvases(
      workspace: workspace,
      activeDocument: draftDocument
    )
    let policy = try #require(compilation.policies.first)

    #expect(compilation.policies.count == 1)
    #expect(policy.eventSource == .manualOCRPaste)
    #expect(policy.executionPlan?.fanOuts.first?.payload == .text)
  }

  @Test("workspace compilation assigns stable priorities across multiple enforced canvases")
  func workspaceCompilationAssignsStablePrioritiesAcrossMultipleEnforcedCanvases() throws {
    let defaultDocument = TaskBoardPolicyPipelineDocument(
      revision: 1,
      mode: .draft,
      nodes: [],
      edges: [],
      groups: []
    )
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
          canvasId: "manual-ocr-canvas",
          title: "Manual OCR Paste",
          document: policyCanvasManualOCRPasteDocument()
        ),
        policyCanvasSummary(
          canvasId: "review-screenshot-canvas",
          title: "PR screenshot extraction",
          document: policyCanvasReviewScreenshotExtractionDocument()
        ),
      ]
    )

    let compilation = PolicyCanvasAutomationPolicyCompiler.compileEnforcedCanvases(
      workspace: workspace,
      activeDocument: defaultDocument
    )

    #expect(
      compilation.policies.map(\.eventSource) == [
        .manualOCRPaste,
        .reviewScreenshotPaste,
      ])
    #expect(compilation.policies.map(\.priority) == [1, 2])
    #expect(Set(compilation.policies.map(\.id)).count == 2)
  }

  @Test("workspace compilation stops when global enforcement is disabled")
  func workspaceCompilationStopsWhenGlobalEnforcementIsDisabled() throws {
    let defaultDocument = TaskBoardPolicyPipelineDocument(
      revision: 1,
      mode: .draft,
      nodes: [],
      edges: [],
      groups: []
    )
    let workspace = TaskBoardPolicyCanvasWorkspace(
      schemaVersion: 1,
      activeCanvasId: "default-canvas",
      canvases: [
        policyCanvasSummary(
          canvasId: "manual-ocr-canvas",
          title: "Manual OCR Paste",
          document: policyCanvasManualOCRPasteDocument()
        )
      ],
      globalPolicyEnforcementEnabled: false
    )

    let compilation = PolicyCanvasAutomationPolicyCompiler.compileEnforcedCanvases(
      workspace: workspace,
      activeDocument: defaultDocument
    )

    #expect(compilation == .empty)
  }

  @Test("workspace compilation does not request the active document")
  func workspaceCompilationDoesNotRequestTheActiveDocument() {
    var activeDocumentWasRequested = false
    let workspace = TaskBoardPolicyCanvasWorkspace(
      schemaVersion: 1,
      activeCanvasId: "default-canvas",
      canvases: []
    )

    let compilation = PolicyCanvasAutomationPolicyCompiler.compileEnforcedCanvases(
      workspace: workspace,
      activeDocument: {
        activeDocumentWasRequested = true
        return TaskBoardPolicyPipelineDocument(
          revision: 1,
          mode: .enforced,
          nodes: [],
          edges: [],
          groups: []
        )
      }()
    )

    #expect(compilation == .empty)
    #expect(!activeDocumentWasRequested)
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
        kind: .actionStep(PolicyActionStep(actionId: "automation.review_text_paste")),
        automation: .canvasDefault(source: .manualReviewTextPaste),
        inputs: [],
        outputs: ["default"]
      ),
      policyCanvasPipelineNode(
        id: "automation:review-text-paste:dry-run",
        title: "Dry-run gate",
        kind: .dryRunGate(reasonCode: .dryRunRequired),
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

func policyCanvasManualOCRPasteDocument() -> TaskBoardPolicyPipelineDocument {
  TaskBoardPolicyPipelineDocument(
    revision: 1,
    mode: .enforced,
    nodes: [
      policyCanvasPipelineNode(
        id: "automation:manual-ocr-paste:source",
        title: "Manual OCR Paste",
        kind: .actionStep(PolicyActionStep(actionId: "automation.manual_ocr_paste")),
        automation: .canvasDefault(source: .manualOCRPaste),
        inputs: [],
        outputs: ["image"]
      ),
      policyCanvasPipelineNode(
        id: "automation:manual-ocr-paste:ocr",
        title: "OCR image",
        kind: .ocrImage,
        automation: .canvasComponent(actions: [.ocrImage]),
        inputs: ["in"],
        outputs: ["text"]
      ),
      policyCanvasPipelineNode(
        id: "automation:manual-ocr-paste:hub",
        title: "Hub",
        kind: .hub,
        inputs: ["in"],
        outputs: ["out_1", "out_2"]
      ),
      policyCanvasPipelineNode(
        id: "automation:manual-ocr-paste:debug",
        title: "Open Debugging",
        kind: .actionStep(PolicyActionStep(actionId: "dashboard.open_debugging")),
        automation: .canvasComponent(actions: [.openDashboardDebugging]),
        inputs: ["in"],
        outputs: []
      ),
      policyCanvasPipelineNode(
        id: "automation:manual-ocr-paste:persist",
        title: "Persist OCR result",
        kind: .actionStep(PolicyActionStep(actionId: "ocr.persist_result")),
        automation: .canvasComponent(
          actions: [.rememberRecentScan, .showFeedback, .recordMetadata],
          postprocessors: [.sourceSpecificTextCleanup, .persistResult, .auditEvent]
        ),
        inputs: ["in"],
        outputs: []
      ),
    ],
    edges: [
      TaskBoardPolicyPipelineEdge(
        id: "edge:manual-ocr-paste:ocr",
        fromNodeId: "automation:manual-ocr-paste:source",
        fromPort: "image",
        toNodeId: "automation:manual-ocr-paste:ocr",
        toPort: "in"
      ),
      TaskBoardPolicyPipelineEdge(
        id: "edge:manual-ocr-paste:hub",
        fromNodeId: "automation:manual-ocr-paste:ocr",
        fromPort: "text",
        toNodeId: "automation:manual-ocr-paste:hub",
        toPort: "in"
      ),
      TaskBoardPolicyPipelineEdge(
        id: "edge:manual-ocr-paste:debug",
        fromNodeId: "automation:manual-ocr-paste:hub",
        fromPort: "out_1",
        toNodeId: "automation:manual-ocr-paste:debug",
        toPort: "in"
      ),
      TaskBoardPolicyPipelineEdge(
        id: "edge:manual-ocr-paste:persist",
        fromNodeId: "automation:manual-ocr-paste:hub",
        fromPort: "out_2",
        toNodeId: "automation:manual-ocr-paste:persist",
        toPort: "in"
      ),
    ],
    groups: []
  )
}

func policyCanvasReviewScreenshotExtractionDocument() -> TaskBoardPolicyPipelineDocument {
  TaskBoardPolicyPipelineDocument(
    revision: 1,
    mode: .enforced,
    nodes: [
      policyCanvasPipelineNode(
        id: "automation:review-screenshot:source",
        title: "Review Screenshot Paste",
        kind: .reviewScreenshotPaste,
        automation: .canvasDefault(source: .reviewScreenshotPaste),
        inputs: [],
        outputs: ["image"]
      ),
      policyCanvasPipelineNode(
        id: "automation:review-screenshot:ocr",
        title: "OCR image",
        kind: .ocrImage,
        automation: .canvasComponent(actions: [.ocrImage]),
        inputs: ["in"],
        outputs: ["text"]
      ),
      policyCanvasPipelineNode(
        id: "automation:review-screenshot:hub",
        title: "Hub",
        kind: .hub,
        inputs: ["in"],
        outputs: ["out_1", "out_2"]
      ),
      policyCanvasPipelineNode(
        id: "automation:review-screenshot:resolve",
        title: "Resolve Reviews PRs",
        kind: .resolveReviewPullRequests,
        automation: .canvasComponent(actions: [
          .extractGitHubPullRequests,
          .resolveReviewPullRequests,
        ]),
        inputs: ["in"],
        outputs: ["pull_requests"]
      ),
      policyCanvasPipelineNode(
        id: "automation:review-screenshot:copy",
        title: "Copy extracted PR URLs",
        kind: .actionStep(PolicyActionStep(actionId: "github.copy_extracted_pull_request_urls")),
        automation: .canvasComponent(actions: [.copyExtractedGitHubPullRequestURLs]),
        inputs: ["in"],
        outputs: []
      ),
    ],
    edges: [
      TaskBoardPolicyPipelineEdge(
        id: "edge:review-screenshot:ocr",
        fromNodeId: "automation:review-screenshot:source",
        fromPort: "image",
        toNodeId: "automation:review-screenshot:ocr",
        toPort: "in"
      ),
      TaskBoardPolicyPipelineEdge(
        id: "edge:review-screenshot:hub",
        fromNodeId: "automation:review-screenshot:ocr",
        fromPort: "text",
        toNodeId: "automation:review-screenshot:hub",
        toPort: "in"
      ),
      TaskBoardPolicyPipelineEdge(
        id: "edge:review-screenshot:resolve",
        fromNodeId: "automation:review-screenshot:hub",
        fromPort: "out_1",
        toNodeId: "automation:review-screenshot:resolve",
        toPort: "in"
      ),
      TaskBoardPolicyPipelineEdge(
        id: "edge:review-screenshot:copy",
        fromNodeId: "automation:review-screenshot:hub",
        fromPort: "out_2",
        toNodeId: "automation:review-screenshot:copy",
        toPort: "in"
      ),
    ],
    groups: []
  )
}

private func policyCanvasSummary(
  canvasId: String,
  title: String,
  document: TaskBoardPolicyPipelineDocument,
  liveDocument: TaskBoardPolicyPipelineDocument? = nil
) -> TaskBoardPolicyCanvasSummary {
  TaskBoardPolicyCanvasSummary(
    canvasId: canvasId,
    title: title,
    revision: document.revision,
    mode: document.mode,
    document: document,
    liveDocument: liveDocument,
    nodeCount: document.nodes.count,
    edgeCount: document.edges.count,
    groupCount: document.groups.count,
    updatedAt: "2026-05-30T00:00:00Z"
  )
}

private func policyCanvasPipelineNode(
  id: String,
  title: String,
  kind: PolicyGraphNodeKind,
  automation: PolicyGraphAutomationBinding? = nil,
  inputs: [String],
  outputs: [String]
) -> TaskBoardPolicyPipelineNode {
  TaskBoardPolicyPipelineNode(
    id: PolicyGraphNodeId(id),
    title: title,
    kind: kind,
    automation: automation,
    inputs: inputs.map { TaskBoardPolicyPipelinePort(id: PolicyGraphPortId($0), title: $0) },
    outputs: outputs.map { TaskBoardPolicyPipelinePort(id: PolicyGraphPortId($0), title: $0) }
  )
}
