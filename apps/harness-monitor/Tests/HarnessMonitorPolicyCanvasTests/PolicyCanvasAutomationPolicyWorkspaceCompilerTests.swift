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

