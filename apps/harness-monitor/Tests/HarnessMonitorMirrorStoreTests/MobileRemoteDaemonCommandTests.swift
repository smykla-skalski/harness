import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto
import HarnessMonitorMirrorStore
import XCTest

final class MobileRemoteDaemonCommandTests: XCTestCase {
  override func setUp() {
    super.setUp()
    RemoteDaemonCommandURLProtocol.reset()
  }

  override func tearDown() {
    RemoteDaemonCommandURLProtocol.reset()
    super.tearDown()
  }

  func testOperatorDirectClientSupportsCommands() throws {
    let client = try makeClient(role: .operator, scopes: ["read", "write"])

    XCTAssertTrue(client.supportsCommands)
  }

  func testSyncClientsDefaultToCommandsUnavailable() {
    XCTAssertFalse(SnapshotOnlyCommandSyncClient().supportsCommands)
  }

  func testRefreshCommandUsesAuthenticatedDirectRoute() async throws {
    RemoteDaemonCommandURLProtocol.respond(statusCode: 200, body: #"{"status":"ok"}"#)
    let client = try makeClient(role: .operator, scopes: ["read", "write"])
    let now = Date(timeIntervalSince1970: 1_752_124_400)

    _ = try await client.queueCommand(
      makeRemoteDaemonCommand(kind: .refresh, payload: ["scope": "health"], now: now),
      currentRevision: 42,
      now: now
    )

    let request = try XCTUnwrap(RemoteDaemonCommandURLProtocol.requests.first)
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertEqual(request.url?.absoluteString, "https://daemon.example.com/v1/health")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer server-token")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "x-harness-remote-client-id"),
      "ios-device"
    )
  }

  func testDirectSubmissionReturnsTerminalReceipt() async throws {
    RemoteDaemonCommandURLProtocol.respond(statusCode: 200, body: #"{"status":"ok"}"#)
    let client = try makeClient(role: .operator, scopes: ["read", "write"])
    let now = Date(timeIntervalSince1970: 1_752_124_400)
    let command = makeRemoteDaemonCommand(
      kind: .refresh,
      payload: ["scope": "health"],
      now: now
    )

    let submission = try await client.queueCommand(
      command,
      currentRevision: 42,
      now: now
    )

    XCTAssertEqual(submission.disposition, .completed)
    XCTAssertEqual(submission.command.status, .succeeded)
    XCTAssertEqual(submission.command.updatedAt, now)
    XCTAssertEqual(submission.command.receipt?.status, .succeeded)
    XCTAssertEqual(submission.command.receipt?.receivedAt, now)
    XCTAssertEqual(submission.command.receipt?.completedAt, now)
    XCTAssertEqual(submission.command.receipt?.executionRevision, 42)
  }

  func testViewerCannotSubmitDirectCommands() async throws {
    let client = try makeClient(role: .viewer, scopes: ["read"])

    XCTAssertFalse(client.supportsCommands)
    do {
      _ = try await client.queueCommand(
        makeRemoteDaemonCommand(kind: .refresh, payload: ["scope": "health"]),
        currentRevision: 42,
        now: Date(timeIntervalSince1970: 1_752_124_400)
      )
      XCTFail("expected commands unavailable")
    } catch let error as MobileRemoteDaemonSyncError {
      XCTAssertEqual(error, .commandsUnavailable)
    }
    XCTAssertTrue(RemoteDaemonCommandURLProtocol.requests.isEmpty)
  }

  func testAdminCanSubmitBeforeScopeExpansion() throws {
    let client = try makeClient(role: .admin, scopes: [])

    XCTAssertTrue(client.supportsCommands)
  }

  func testLiveFactoryEnablesCommandsForRemoteOperatorCredential() throws {
    let access = try makeRemoteDaemonCommandAccess(
      role: .operator,
      scopes: ["read", "write"]
    )
    let credential = MobilePairedStationCredential(
      stationID: "station-1",
      stationName: "daemon.example.com",
      endpoint: access.endpoint,
      stationPublicKeyFingerprint: access.serverSPKISHA256.value,
      deviceIdentityID: "phone-identity",
      snapshotKeyID: "",
      commandKeyID: "",
      symmetricKeyRawRepresentation: Data(),
      pairedAt: access.pairedAt,
      defaultStation: true,
      remoteDaemonAccess: access
    )
    let identity = MobileDeviceIdentity(
      id: "phone-identity",
      displayName: "Phone",
      createdAt: access.pairedAt
    )

    let client = LiveMobileMonitorSyncClientFactory().makeSyncClient(
      credential: credential,
      identity: identity
    )

    XCTAssertTrue(client.supportsCommands)
  }

  func testExpiredCommandIsRejectedBeforeNetwork() async throws {
    let client = try makeClient(role: .operator, scopes: ["read", "write"])
    let createdAt = Date(timeIntervalSince1970: 1_752_124_400)
    let now = createdAt.addingTimeInterval(601)

    do {
      _ = try await client.queueCommand(
        makeRemoteDaemonCommand(
          kind: .refresh,
          payload: ["scope": "health"],
          now: createdAt
        ),
        currentRevision: 42,
        now: now
      )
      XCTFail("expected command expiry")
    } catch let error as MobileRemoteDaemonSyncError {
      XCTAssertEqual(error, .commandExpired)
    }
    XCTAssertTrue(RemoteDaemonCommandURLProtocol.requests.isEmpty)
  }

  func testRemoteAuthorizationFailuresRemainFailClosed() async throws {
    let client = try makeClient(role: .operator, scopes: ["read", "write"])
    let command = makeRemoteDaemonCommand(kind: .refresh, payload: ["scope": "health"])
    for (statusCode, expectedError) in [
      (401, MobileRemoteDaemonSyncError.unauthorized),
      (403, MobileRemoteDaemonSyncError.forbidden),
    ] {
      RemoteDaemonCommandURLProtocol.respond(statusCode: statusCode, body: "{}")
      do {
        _ = try await client.queueCommand(
          command,
          currentRevision: 42,
          now: command.createdAt
        )
        XCTFail("expected authorization failure")
      } catch let error as MobileRemoteDaemonSyncError {
        XCTAssertEqual(error, expectedError)
      }
    }
  }

  func testDirectMutationFailureDoesNotFallBackToCloud() async throws {
    RemoteDaemonCommandURLProtocol.respond(statusCode: 503, body: "{}")
    let cloud = RecordingCommandSyncClient()
    let client = DirectFirstMobileMonitorSyncClient(
      direct: try makeClient(role: .operator, scopes: ["read", "write"]),
      cloudFallback: cloud
    )
    let command = makeRemoteDaemonCommand(kind: .refresh, payload: ["scope": "health"])

    do {
      _ = try await client.queueCommand(
        command,
        currentRevision: 42,
        now: command.createdAt
      )
      XCTFail("expected server failure")
    } catch let error as MobileRemoteDaemonSyncError {
      XCTAssertEqual(error, .serverStatus(503))
    }
    let submissionCount = await cloud.submissionCount()
    XCTAssertEqual(submissionCount, 0)
  }

  func testHybridViewerUsesCloudCommandTransport() async throws {
    let cloud = RecordingCommandSyncClient()
    let client = DirectFirstMobileMonitorSyncClient(
      direct: try makeClient(role: .viewer, scopes: ["read"]),
      cloudFallback: cloud
    )
    let command = makeRemoteDaemonCommand(kind: .refresh, payload: ["scope": "health"])

    let submission = try await client.queueCommand(
      command,
      currentRevision: 42,
      now: command.createdAt
    )

    XCTAssertEqual(submission.disposition, .queued)
    XCTAssertEqual(submission.command.id, command.id)
    let submissionCount = await cloud.submissionCount()
    XCTAssertEqual(submissionCount, 1)
    XCTAssertTrue(RemoteDaemonCommandURLProtocol.requests.isEmpty)
  }

  func testHybridDirectCommandDoesNotCancelThroughCloud() async throws {
    let cloud = RecordingCommandSyncClient()
    let client = DirectFirstMobileMonitorSyncClient(
      direct: try makeClient(role: .operator, scopes: ["read", "write"]),
      cloudFallback: cloud
    )
    let command = makeRemoteDaemonCommand(kind: .refresh, payload: ["scope": "health"])

    do {
      _ = try await client.cancelCommand(
        command,
        currentRevision: 42,
        now: command.createdAt
      )
      XCTFail("direct commands do not have a CloudMirror cancellation")
    } catch let error as MobileRemoteDaemonSyncError {
      XCTAssertEqual(error, .commandsUnavailable)
    }
    let cancellationCount = await cloud.cancellationCount()
    XCTAssertEqual(cancellationCount, 0)
  }

  private func makeClient(
    role: MobileRemoteDaemonRole,
    scopes: [String]
  ) throws -> MobileRemoteDaemonSyncClient {
    try makeRemoteDaemonCommandClient(role: role, scopes: scopes)
  }
}

private struct SnapshotOnlyCommandSyncClient: MobileMonitorSyncClient {
  func fetchLatestSnapshot(
    stationID: String,
    now: Date
  ) async throws -> MobileMirrorSnapshot? {
    nil
  }

  func queueCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileCommandSubmission {
    throw MobileRemoteDaemonSyncError.commandsUnavailable
  }

  func cancelCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileCommandReceipt {
    throw MobileRemoteDaemonSyncError.commandsUnavailable
  }
}
