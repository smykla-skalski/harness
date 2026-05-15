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

  @Test("HTTP client uses task-board route contract")
  func httpClientUsesTaskBoardRoutes() async throws {
    let result = try await performHTTPClientContractCalls()
    let records = TaskBoardURLProtocol.records

    assertHTTPRouteContract(records)
    assertHTTPBodyContract(records)
    assertHTTPClientResults(result)
  }

  @Test("WebSocket transport uses task-board RPC contract")
  func webSocketTransportUsesTaskBoardRPCContract() async throws {
    let result = try await performWebSocketContractCalls()

    assertWebSocketRPCContract(result.calls)
    assertWebSocketPayloadContract(result.calls)
    assertWebSocketResults(result)
  }

  @Test("Recording client implements task-board orchestrator contract")
  func recordingClientImplementsTaskBoardOrchestratorContract() async throws {
    let client = RecordingHarnessClient()

    let status = try await client.taskBoardOrchestratorStatus()
    _ = try await client.taskBoardOrchestratorSettings()
    let runtimeConfig = try await client.taskBoardGitRuntimeConfig()
    _ = try await client.startTaskBoardOrchestrator()
    _ = try await client.stopTaskBoardOrchestrator()
    let runOnce = try await client.runTaskBoardOrchestratorOnce(
      request: TaskBoardOrchestratorRunOnceRequest(
        dryRun: false,
        status: .todo,
        projectDir: "/tmp/harness"
      )
    )
    let settings = try await client.updateTaskBoardOrchestratorSettings(
      request: TaskBoardOrchestratorSettingsUpdateRequest(
        clearDispatchStatusFilter: true,
        clearProjectDir: true,
        githubInbox: TaskBoardGitHubInboxConfig(repositories: ["example/harness", "example/aff"]),
        policyVersion: "task-board-policy-v3"
      )
    )
    let updatedRuntimeConfig = try await client.updateTaskBoardGitRuntimeConfig(
      request: TaskBoardGitRuntimeConfig(
        repositoryOverrides: [
          TaskBoardGitRepositoryOverride(repository: "example/harness")
        ]
      )
    )
    let tokenSync = try await client.syncTaskBoardGitHubTokens(
      request: TaskBoardGitHubTokensSyncRequest(
        globalToken: "ghu_global",
        repositoryTokens: [
          TaskBoardGitHubRepositoryToken(repository: "example/harness", token: "ghu_repo")
        ]
      )
    )
    let todoistTokenSync = try await client.syncTaskBoardTodoistToken(
      request: TaskBoardTodoistTokenSyncRequest(token: "todoist-token")
    )

    #expect(status.settings.githubProject.owner == "example")
    #expect(status.settings.githubProject.repo == "harness")
    #expect(runtimeConfig.global.authorName == "Harness Bot")
    #expect(runOnce.lastRun?.sync.total == 1)
    #expect(runOnce.lastRun?.policyTraceIds == ["trace-1"])
    #expect(settings.githubInbox.repositories == ["example/harness", "example/aff"])
    #expect(settings.policyVersion == "task-board-policy-v3")
    #expect(updatedRuntimeConfig.repositoryOverrides.first?.repository == "example/harness")
    #expect(tokenSync.globalTokenConfigured == true)
    #expect(tokenSync.repositoryTokenCount == 1)
    #expect(todoistTokenSync.tokenConfigured == true)
    #expect(
      client.calls == [
        .startTaskBoardOrchestrator,
        .stopTaskBoardOrchestrator,
        .runTaskBoardOrchestratorOnce(
          itemID: nil,
          dryRun: false,
          status: .todo,
          projectDir: "/tmp/harness"
        ),
        .updateTaskBoardOrchestratorSettings(
          policyVersion: "task-board-policy-v3",
          clearProjectDir: true,
          clearDispatchStatusFilter: true
        ),
        .updateTaskBoardGitRuntimeConfig(overrideCount: 1),
        .syncTaskBoardGitHubTokens(globalTokenConfigured: true, repositoryTokenCount: 1),
        .syncTaskBoardTodoistToken(tokenConfigured: true),
      ]
    )
  }

  private func taskBoardDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }
}
