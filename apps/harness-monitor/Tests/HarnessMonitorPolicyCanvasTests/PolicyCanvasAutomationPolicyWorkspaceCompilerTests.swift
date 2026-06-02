import Foundation
import HarnessMonitorKit
import Testing

@testable import HarnessMonitorPolicyCanvas

@Suite("Policy canvas automation policy workspace compiler")
@MainActor
struct PolicyCanvasAutomationPolicyWorkspaceCompilerTests {
  @Test("workspace decoding accepts legacy review extraction config")
  func workspaceDecodingAcceptsLegacyReviewExtractionConfig() throws {
    let data =
      """
      {
        "schemaVersion": 1,
        "activeCanvasId": "default-canvas",
        "policyEnforcementKillSwitchActive": false,
        "canvases": [
          {
            "canvasId": "default-canvas",
            "title": "Default",
            "revision": 1,
            "mode": "draft",
            "nodeCount": 0,
            "edgeCount": 0,
            "groupCount": 0,
            "updatedAt": "2026-06-02T12:00:00Z",
            "document": {
              "schemaVersion": 2,
              "revision": 1,
              "mode": "draft",
              "nodes": [],
              "edges": [],
              "groups": [],
              "layout": { "nodes": [] },
              "policyTraceIds": []
            }
          },
          {
            "canvasId": "pasted-pr-approvals",
            "title": "Pasted PR approvals",
            "revision": 7,
            "mode": "draft",
            "nodeCount": 0,
            "edgeCount": 0,
            "groupCount": 0,
            "updatedAt": "2026-06-02T12:00:00Z",
            "document": {
              "schemaVersion": 2,
              "revision": 7,
              "mode": "draft",
              "nodes": [],
              "edges": [],
              "groups": [],
              "layout": { "nodes": [] },
              "policyTraceIds": []
            }
          },
          {
            "canvasId": "pr-screenshot-extraction",
            "title": "PR screenshot extraction",
            "revision": 1,
            "mode": "enforced",
            "nodeCount": 1,
            "edgeCount": 0,
            "groupCount": 0,
            "updatedAt": "2026-06-02T12:00:00Z",
            "document": {
              "schemaVersion": 2,
              "revision": 1,
              "mode": "enforced",
              "nodes": [
                {
                  "id": "automation:review-screenshot:source",
                  "label": "Review Screenshot Paste",
                  "kind": { "kind": "action_step" },
                  "automation": {
                    "isEnabled": true,
                    "eventSource": "reviewScreenshotPaste",
                    "contentKinds": ["image"],
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
                    "sourceAppMode": "allExceptDenied",
                    "reviewPullRequestExtraction": {
                      "repositoryMode": "allConfiguredRepos",
                      "numberMemoryEnabled": true,
                      "resultScope": "all",
                      "failureSignalMode": "liveOrVisual",
                      "outputFormat": "newlineGitHubURLs",
                      "autoCopy": true,
                      "showSheet": true
                    }
                  },
                  "inputPorts": [],
                  "outputPorts": ["default"]
                }
              ],
              "edges": [],
              "groups": [],
              "layout": { "nodes": [] },
              "policyTraceIds": []
            }
          }
        ]
      }
      """.data(using: .utf8)!

    let workspace = try JSONDecoder().decode(TaskBoardPolicyCanvasWorkspace.self, from: data)
    let extraction = try #require(
      workspace.canvases[2].document?.nodes[0].automation?.reviewPullRequestExtraction
    )

    #expect(workspace.canvases.map(\.title) == [
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
    #expect(policy.actions.contains(.copyReviewPullRequestList))
    #expect(policy.ocrConfiguration == AutomationPolicyOCRConfiguration())
    #expect(policy.reviewPullRequestExtraction == ReviewPullRequestExtractionConfiguration())
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

func policyCanvasReviewScreenshotExtractionDocument() -> TaskBoardPolicyPipelineDocument {
  TaskBoardPolicyPipelineDocument(
    revision: 1,
    mode: .enforced,
    nodes: [
      policyCanvasPipelineNode(
        id: "automation:review-screenshot:source",
        title: "Review Screenshot Paste",
        kind: TaskBoardPolicyPipelineNodeKind(kind: "review_screenshot_paste"),
        automation: .canvasDefault(source: .reviewScreenshotPaste),
        inputs: [],
        outputs: ["image"]
      ),
      policyCanvasPipelineNode(
        id: "automation:review-screenshot:ocr",
        title: "OCR screenshot rows",
        kind: TaskBoardPolicyPipelineNodeKind(kind: "ocr_image"),
        automation: .canvasComponent(actions: [.ocrImage]),
        inputs: ["in"],
        outputs: ["text"]
      ),
      policyCanvasPipelineNode(
        id: "automation:review-screenshot:resolve",
        title: "Resolve Reviews PRs",
        kind: TaskBoardPolicyPipelineNodeKind(kind: "resolve_review_pull_requests"),
        automation: .canvasComponent(actions: [
          .extractGitHubPullRequests,
          .resolveReviewPullRequests,
        ]),
        inputs: ["in"],
        outputs: ["pull_requests"]
      ),
      policyCanvasPipelineNode(
        id: "automation:review-screenshot:copy",
        title: "Copy PR list",
        kind: TaskBoardPolicyPipelineNodeKind(kind: "copy_review_pull_request_list"),
        automation: .canvasComponent(actions: [.copyReviewPullRequestList]),
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
        id: "edge:review-screenshot:resolve",
        fromNodeId: "automation:review-screenshot:ocr",
        fromPort: "text",
        toNodeId: "automation:review-screenshot:resolve",
        toPort: "in"
      ),
      TaskBoardPolicyPipelineEdge(
        id: "edge:review-screenshot:copy",
        fromNodeId: "automation:review-screenshot:resolve",
        fromPort: "pull_requests",
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
