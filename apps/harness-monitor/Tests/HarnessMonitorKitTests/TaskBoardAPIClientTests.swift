import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Task-board daemon API client", .serialized)
struct TaskBoardAPIClientTests {
  @Test("Git runtime config decodes daemon default payload")
  func gitRuntimeConfigDecodesDaemonDefaultPayload() throws {
    let data = Data(#"{"global":{"signing":{"mode":"none"}}}"#.utf8)

    let config = try taskBoardDecoder().decode(TaskBoardGitRuntimeConfig.self, from: data)

    #expect(config.global.signing.mode == .none)
    #expect(config.global.authorName == nil)
    #expect(config.repositoryOverrides.isEmpty)
  }

  @Test("Git runtime config decodes inline key material")
  func gitRuntimeConfigDecodesInlineKeyMaterial() throws {
    let data = Data(
      #"""
      {
        "global": {
          "ssh_private_key": "ssh-secret",
          "ssh_private_key_passphrase": "ssh-passphrase",
          "signing": {
            "mode": "gpg",
            "ssh_private_key": "signing-ssh-secret",
            "ssh_private_key_passphrase": "signing-ssh-passphrase",
            "gpg_private_key": "gpg-secret",
            "gpg_private_key_passphrase": "gpg-passphrase"
          }
        }
      }
      """#.utf8
    )

    let config = try taskBoardDecoder().decode(TaskBoardGitRuntimeConfig.self, from: data)

    #expect(config.global.sshPrivateKey == "ssh-secret")
    #expect(config.global.sshPrivateKeyPassphrase == "ssh-passphrase")
    #expect(config.global.signing.sshPrivateKey == "signing-ssh-secret")
    #expect(config.global.signing.sshPrivateKeyPassphrase == "signing-ssh-passphrase")
    #expect(config.global.signing.gpgPrivateKey == "gpg-secret")
    #expect(config.global.signing.gpgPrivateKeyPassphrase == "gpg-passphrase")
  }

  @Test("GitHub project config decodes requested reviewers")
  func githubProjectConfigDecodesRequestedReviewers() throws {
    let data = Data(
      #"""
      {
        "requested_reviewers": {
          "reviewers": ["alice", "bob"],
          "team_reviewers": ["platform"]
        }
      }
      """#.utf8
    )

    let config = try taskBoardDecoder().decode(TaskBoardGitHubProjectConfig.self, from: data)

    #expect(config.requestedReviewers.reviewers == ["alice", "bob"])
    #expect(config.requestedReviewers.teamReviewers == ["platform"])
  }

  @Test("Task board item decodes omitted daemon default fields")
  func taskBoardItemDecodesOmittedDaemonDefaultFields() throws {
    let data = Data(
      #"""
      {
        "schema_version": 1,
        "id": "board-1",
        "title": "Board item",
        "body": "Body",
        "status": "todo",
        "priority": "high",
        "agent_mode": "interactive",
        "planning": {},
        "workflow": {
          "status": "running"
        },
        "usage": {},
        "created_at": "2026-05-14T10:00:00Z",
        "updated_at": "2026-05-14T10:01:00Z"
      }
      """#.utf8
    )

    let item = try taskBoardDecoder().decode(TaskBoardItem.self, from: data)

    #expect(item.tags.isEmpty)
    #expect(item.externalRefs.isEmpty)
    #expect(item.workflow?.attempts == 0)
    #expect(item.workflow?.policyTraceIds.isEmpty == true)
  }

  @Test("Task board item preserves present workflow and collection fields")
  func taskBoardItemPreservesPresentWorkflowAndCollectionFields() throws {
    let data = Data(
      #"""
      {
        "schema_version": 1,
        "id": "board-1",
        "title": "Board item",
        "body": "Body",
        "status": "todo",
        "priority": "high",
        "tags": ["automation"],
        "project_id": "owner/repo",
        "agent_mode": "interactive",
        "external_refs": [
          {
            "provider": "git_hub",
            "external_id": "123",
            "url": "https://example.invalid/issues/123"
          }
        ],
        "planning": {},
        "workflow": {
          "status": "running",
          "attempts": 2,
          "policy_trace_ids": ["trace-1"]
        },
        "usage": {},
        "created_at": "2026-05-14T10:00:00Z",
        "updated_at": "2026-05-14T10:01:00Z"
      }
      """#.utf8
    )

    let item = try taskBoardDecoder().decode(TaskBoardItem.self, from: data)

    #expect(item.tags == ["automation"])
    #expect(item.externalRefs.first?.provider == .gitHub)
    #expect(item.workflow?.attempts == 2)
    #expect(item.workflow?.policyTraceIds == ["trace-1"])
  }

  @Test("Task board item decodes empty target project types when field omitted")
  func taskBoardItemDecodesEmptyTargetProjectTypes() throws {
    let data = Data(
      #"""
      {
        "schema_version": 1,
        "id": "board-1",
        "title": "Board item",
        "body": "Body",
        "status": "todo",
        "priority": "medium",
        "agent_mode": "headless",
        "planning": {},
        "usage": {},
        "created_at": "2026-05-14T10:00:00Z",
        "updated_at": "2026-05-14T10:01:00Z"
      }
      """#.utf8
    )

    let item = try taskBoardDecoder().decode(TaskBoardItem.self, from: data)

    #expect(item.targetProjectTypes.isEmpty)
  }

  @Test("Task board item round trips target project types")
  func taskBoardItemRoundTripsTargetProjectTypes() throws {
    let data = Data(
      #"""
      {
        "schema_version": 1,
        "id": "board-1",
        "title": "Board item",
        "body": "Body",
        "status": "todo",
        "priority": "medium",
        "target_project_types": ["web", "data"],
        "agent_mode": "headless",
        "planning": {},
        "usage": {},
        "created_at": "2026-05-14T10:00:00Z",
        "updated_at": "2026-05-14T10:01:00Z"
      }
      """#.utf8
    )

    let item = try taskBoardDecoder().decode(TaskBoardItem.self, from: data)

    #expect(item.targetProjectTypes == ["web", "data"])
  }

  @Test("Task board create request encodes target project types as snake case")
  func taskBoardCreateItemRequestEncodesTargetProjectTypes() throws {
    let request = TaskBoardCreateItemRequest(
      title: "Routed",
      targetProjectTypes: ["web", "data"]
    )

    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = try encoder.encode(request)
    let json = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )

    #expect(json["target_project_types"] as? [String] == ["web", "data"])
  }

  @Test("Task board update request includes target project types when set")
  func taskBoardUpdateItemRequestEncodesTargetProjectTypes() throws {
    let request = TaskBoardUpdateItemRequest(
      targetProjectTypes: ["web"]
    )

    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = try encoder.encode(request)
    let json = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )

    #expect(json["target_project_types"] as? [String] == ["web"])
  }

  @Test("Task board item decodes needs-you status")
  func taskBoardItemDecodesNeedsYouStatus() throws {
    let data = Data(
      #"""
      {
        "schema_version": 1,
        "id": "board-1",
        "title": "Board item",
        "body": "Body",
        "status": "needs_you",
        "priority": "medium",
        "agent_mode": "headless",
        "planning": {},
        "usage": {},
        "created_at": "2026-05-14T10:00:00Z",
        "updated_at": "2026-05-14T10:01:00Z"
      }
      """#.utf8
    )

    let item = try taskBoardDecoder().decode(TaskBoardItem.self, from: data)

    #expect(item.status == .needsYou)
  }

  @Test("Task board orchestrator settings decode missing GitHub inbox config")
  func orchestratorSettingsDecodeMissingGitHubInboxConfig() throws {
    let data = Data(
      #"""
      {
        "enabled_workflows": ["default_task"],
        "dry_run_default": true,
        "github_project": {
          "owner": "example",
          "repo": "harness",
          "checkout_path": "/tmp/harness",
          "default_branch": "main",
          "branch_prefix": "c/",
          "merge_method": "squash",
          "labels": {
            "managed": "harness:managed",
            "auto_merge": "harness:auto-merge",
            "needs_human": "harness:needs-human",
            "protected_path": "harness:protected-path"
          },
          "enabled_automations": {
            "enabled": ["sync_task_board"]
          }
        },
        "policy_version": "task-board-policy-v1"
      }
      """#.utf8
    )

    let settings = try taskBoardDecoder().decode(TaskBoardOrchestratorSettings.self, from: data)

    #expect(settings.githubInbox.repositories.isEmpty)
  }

  @Test("Task board run summary decodes omitted policy trace IDs")
  func taskBoardRunSummaryDecodesOmittedPolicyTraceIDs() throws {
    let data = Data(
      #"""
      {
        "run_id": "run-1",
        "started_at": "2026-05-14T10:00:00Z",
        "completed_at": "2026-05-14T10:01:00Z",
        "status": "completed",
        "dry_run": false,
        "sync": {
          "total": 1,
          "providers": []
        },
        "audit": {
          "total": 1,
          "ready": 1,
          "blocked": 0,
          "deleted": 0,
          "by_status": []
        }
      }
      """#.utf8
    )

    let summary = try taskBoardDecoder().decode(TaskBoardOrchestratorRunSummary.self, from: data)

    #expect(summary.policyTraceIds.isEmpty)
  }

  @Test("Task board run summary preserves present policy trace IDs")
  func taskBoardRunSummaryPreservesPresentPolicyTraceIDs() throws {
    let data = Data(
      #"""
      {
        "run_id": "run-1",
        "started_at": "2026-05-14T10:00:00Z",
        "completed_at": "2026-05-14T10:01:00Z",
        "status": "completed",
        "dry_run": false,
        "sync": {
          "total": 1,
          "providers": []
        },
        "audit": {
          "total": 1,
          "ready": 1,
          "blocked": 0,
          "deleted": 0,
          "by_status": []
        },
        "policy_trace_ids": ["trace-1"]
      }
      """#.utf8
    )

    let summary = try taskBoardDecoder().decode(TaskBoardOrchestratorRunSummary.self, from: data)

    #expect(summary.policyTraceIds == ["trace-1"])
  }
}
