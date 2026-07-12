import Foundation
import HarnessMonitorCore
import HarnessMonitorMirrorStore
import XCTest

final class MobileRemoteDaemonAgentsSyncTests: XCTestCase {
  override func setUp() {
    super.setUp()
    AgentsRemoteDaemonURLProtocol.reset()
  }

  override func tearDown() {
    AgentsRemoteDaemonURLProtocol.reset()
    super.tearDown()
  }

  func testFetchIncludesAuthenticatedManagedAgentsAndAttention() async throws {
    configureAgentsBaseResponses()
    AgentsRemoteDaemonURLProtocol.respond(
      path: "/v1/sessions/session-1/managed-agents",
      body: managedAgentsResponse
    )
    let client = try makeAgentsRemoteClient(canWrite: true)
    let now = Date(timeIntervalSince1970: 1_752_124_400)

    let fetchedSnapshot = try await client.fetchLatestSnapshot(
      stationID: agentsStationID,
      now: now
    )
    let snapshot = try XCTUnwrap(fetchedSnapshot)

    let paths = AgentsRemoteDaemonURLProtocol.requests.compactMap(\.url?.path).sorted()
    XCTAssertEqual(paths, [
      "/v1/sessions",
      "/v1/sessions/session-1/managed-agents",
      "/v1/task-board/items",
    ])
    XCTAssertFalse(paths.contains("/v1/sessions/session-ended/managed-agents"))
    for request in AgentsRemoteDaemonURLProtocol.requests {
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer server-token")
      XCTAssertEqual(
        request.value(forHTTPHeaderField: "x-harness-remote-client-id"),
        "ios-device"
      )
    }

    let session = try XCTUnwrap(snapshot.sessions.first { $0.id == "session-1" })
    XCTAssertEqual(session.agents.map(\.id), ["acp-1", "codex-1", "terminal-1"])
    let terminal = try XCTUnwrap(session.agents.first { $0.family == .terminal })
    XCTAssertEqual(terminal.displayName, "codex worker-1")
    XCTAssertEqual(terminal.status, "Running")
    XCTAssertTrue(terminal.isActive)
    XCTAssertFalse(terminal.isBlocked)
    XCTAssertTrue(terminal.summary.contains("[redacted]"))

    let codex = try XCTUnwrap(session.agents.first { $0.family == .codex })
    XCTAssertEqual(codex.displayName, "Reviewer api_key=[redacted]")
    XCTAssertEqual(codex.status, "Waiting Approval")
    XCTAssertTrue(codex.isActive)
    XCTAssertTrue(codex.isBlocked)
    XCTAssertEqual(codex.pendingApprovalCount, 1)
    XCTAssertTrue(codex.summary.contains("[redacted]"))

    let acp = try XCTUnwrap(session.agents.first { $0.family == .acp })
    XCTAssertEqual(acp.displayName, "ACP api_key=[redacted]")
    XCTAssertEqual(acp.status, "Active")
    XCTAssertTrue(acp.isActive)
    XCTAssertTrue(acp.isBlocked)
    XCTAssertEqual(acp.pendingPermissionCount, 2)
    XCTAssertTrue(acp.summary.contains("[redacted]"))

    XCTAssertFalse(
      session.agents.contains {
        $0.displayName.contains("super-secret") || $0.summary.contains("super-secret")
      }
    )
    let permission = try XCTUnwrap(
      snapshot.attention.first { $0.kind == .acpDecision }
    )
    XCTAssertEqual(permission.commandKind, .acpPermissionDecision)
    XCTAssertEqual(permission.target?.sessionID, "session-1")
    XCTAssertEqual(permission.target?.agentID, "acp-1")
    XCTAssertEqual(permission.commandPayload, [
      "batchID": "batch-1",
      "decision": "approve_all",
    ])
    XCTAssertFalse(permission.title.contains("super-secret"))
    XCTAssertFalse(permission.subtitle.contains("super-secret"))

    let blocked = try XCTUnwrap(
      snapshot.attention.first { $0.kind == .blockedAgent }
    )
    XCTAssertEqual(blocked.commandKind, .agentPrompt)
    XCTAssertEqual(blocked.target?.agentID, "codex-1")
    XCTAssertEqual(
      blocked.commandPayload,
      ["prompt": "Please summarize what you need from me."]
    )
    XCTAssertEqual(snapshot.stations.first?.needsYouCount, 2)
    XCTAssertEqual(snapshot.needsYouCount, 2)
  }

  func testReadOnlyProfileDoesNotExposeManagedAgentActions() async throws {
    configureAgentsBaseResponses()
    AgentsRemoteDaemonURLProtocol.respond(
      path: "/v1/sessions/session-1/managed-agents",
      body: managedAgentsResponse
    )
    let client = try makeAgentsRemoteClient(canWrite: false)

    let fetchedSnapshot = try await client.fetchLatestSnapshot(
      stationID: agentsStationID,
      now: Date(timeIntervalSince1970: 1_752_124_400)
    )
    let snapshot = try XCTUnwrap(fetchedSnapshot)

    XCTAssertEqual(snapshot.attention.count, 2)
    XCTAssertTrue(snapshot.attention.allSatisfy { $0.commandKind == nil })
    XCTAssertTrue(snapshot.attention.allSatisfy { $0.commandPayload.isEmpty })
    XCTAssertTrue(snapshot.attention.allSatisfy { $0.target?.sessionID == "session-1" })
    XCTAssertTrue(snapshot.sortedAttention.allSatisfy { $0.commandKind == nil })
    XCTAssertEqual(snapshot.sortedAttention.count, 2)
  }

  func testMissingManagedAgentsRouteKeepsRemoteSessionsAvailable() async throws {
    configureAgentsBaseResponses()
    AgentsRemoteDaemonURLProtocol.respond(
      path: "/v1/sessions/session-1/managed-agents",
      statusCode: 404,
      body: #"{"error":"not found"}"#
    )
    let client = try makeAgentsRemoteClient(canWrite: true)

    let fetchedSnapshot = try await client.fetchLatestSnapshot(
      stationID: agentsStationID,
      now: Date(timeIntervalSince1970: 1_752_124_400)
    )
    let snapshot = try XCTUnwrap(fetchedSnapshot)

    XCTAssertEqual(snapshot.sessions.count, 2)
    XCTAssertTrue(snapshot.sessions.allSatisfy { $0.agents.isEmpty })
    XCTAssertTrue(snapshot.attention.isEmpty)
  }

  func testManagedAgentsUnauthorizedFailsClosed() async throws {
    configureAgentsBaseResponses()
    AgentsRemoteDaemonURLProtocol.respond(
      path: "/v1/sessions/session-1/managed-agents",
      statusCode: 401,
      body: #"{"error":"unauthorized"}"#
    )
    let client = try makeAgentsRemoteClient(canWrite: true)

    do {
      _ = try await client.fetchLatestSnapshot(stationID: agentsStationID, now: .now)
      XCTFail("expected unauthorized error")
    } catch let error as MobileRemoteDaemonSyncError {
      XCTAssertEqual(error, .unauthorized)
    }
  }

  func testManagedAgentsServerFailureUsesCloudFallback() async throws {
    configureAgentsBaseResponses()
    AgentsRemoteDaemonURLProtocol.respond(
      path: "/v1/sessions/session-1/managed-agents",
      statusCode: 503,
      body: #"{"error":"unavailable"}"#
    )
    let direct = try makeAgentsRemoteClient(canWrite: true)
    let fallback = RecordingAgentsFallback()
    let client = DirectFirstMobileMonitorSyncClient(direct: direct, cloudFallback: fallback)

    let snapshot = try await client.fetchLatestSnapshot(stationID: agentsStationID, now: .now)

    XCTAssertNotNil(snapshot)
    let fallbackFetchCount = await fallback.fetchCount()
    XCTAssertEqual(fallbackFetchCount, 1)
  }
}
