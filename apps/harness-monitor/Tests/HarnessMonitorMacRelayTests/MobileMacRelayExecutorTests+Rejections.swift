import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import HarnessMonitorKit
import HarnessMonitorMacRelay
import XCTest

extension MobileMacRelayExecutorTests {
  func testAPIBackedExecutorRejectsMalformedAcpAndTaskBoardPayloads() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = MobileDemoFixtures.snapshot(now: now)

    await assertExecutorRejects(
      command(
        kind: .acpPermissionDecision,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          agentID: "agent-codex-7",
          targetRevision: snapshot.revision
        ),
        payload: ["batchID": "batch-1", "decision": "approve_some"]
      ),
      snapshot: snapshot,
      expected: .missingPayload("requestIDs")
    )
    await assertExecutorRejects(
      command(
        kind: .taskBoardDispatch,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          taskID: "task-16",
          targetRevision: snapshot.revision
        ),
        payload: ["status": "waiting"]
      ),
      snapshot: snapshot,
      expected: .invalidPayload(key: "status", value: "waiting")
    )
    await assertExecutorRejects(
      command(
        kind: .taskBoardDispatch,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          taskID: "task-16",
          targetRevision: snapshot.revision
        ),
        payload: ["dryRun": "maybe"]
      ),
      snapshot: snapshot,
      expected: .invalidPayload(key: "dryRun", value: "maybe")
    )
  }

  func testAPIBackedExecutorRejectsMalformedAgentStartPayloads() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = MobileDemoFixtures.snapshot(now: now)

    await assertExecutorRejects(
      command(
        kind: .agentStart,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          sessionID: "session-pr-review",
          targetRevision: snapshot.revision
        ),
        payload: ["agent": "codex", "allowCustomModel": "maybe"]
      ),
      snapshot: snapshot,
      expected: .invalidPayload(key: "allowCustomModel", value: "maybe")
    )
    await assertExecutorRejects(
      command(
        kind: .agentStart,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          sessionID: "session-pr-review",
          targetRevision: snapshot.revision
        ),
        payload: ["agent": "codex", "rows": "0"]
      ),
      snapshot: snapshot,
      expected: .invalidPayload(key: "rows", value: "0")
    )
    await assertExecutorRejects(
      command(
        kind: .agentStart,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          sessionID: "session-pr-review",
          targetRevision: snapshot.revision
        ),
        payload: ["agent": "codex", "role": "captain"]
      ),
      snapshot: snapshot,
      expected: .invalidPayload(key: "role", value: "captain")
    )
  }

  func testAPIBackedExecutorRejectsMalformedPullRequestPayloads() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = MobileDemoFixtures.snapshot(now: now)

    await assertExecutorRejects(
      command(
        kind: .pullRequestApprove,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          targetRevision: snapshot.revision
        ),
        payload: ["repository": "smykla-skalski/harness", "number": "zero"]
      ),
      snapshot: snapshot,
      expected: .invalidPayload(key: "number", value: "zero")
    )
    await assertExecutorRejects(
      command(
        kind: .pullRequestApprove,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          reviewID: "review-812",
          targetRevision: snapshot.revision
        ),
        payload: ["isDraft": "maybe"]
      ),
      snapshot: snapshot,
      expected: .invalidPayload(key: "isDraft", value: "maybe")
    )
    await assertExecutorRejects(
      command(
        kind: .pullRequestMerge,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          reviewID: "review-812",
          targetRevision: snapshot.revision
        ),
        payload: ["method": "shipit"]
      ),
      snapshot: snapshot,
      expected: .invalidPayload(key: "method", value: "shipit")
    )
  }

  func testAPIBackedExecutorRejectsMissingCommandTargets() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = MobileDemoFixtures.snapshot(now: now)

    await assertExecutorRejects(
      command(
        kind: .agentStop,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          agentID: " ",
          targetRevision: snapshot.revision
        )
      ),
      snapshot: snapshot,
      expected: .missingTarget("agentID")
    )
    await assertExecutorRejects(
      command(
        kind: .taskBoardDispatch,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          targetRevision: snapshot.revision
        )
      ),
      snapshot: snapshot,
      expected: .missingTarget("taskID")
    )
    await assertExecutorRejects(
      command(
        kind: .refresh,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          sessionID: " ",
          targetRevision: snapshot.revision
        ),
        payload: ["scope": "sessionTasks"]
      ),
      snapshot: snapshot,
      expected: .missingTarget("sessionID")
    )
  }

  func testAPIBackedExecutorClassifiesAgentStartFamilies() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = MobileDemoFixtures.snapshot(now: now)
    let client = RecordingMobileRelayCommandClient()
    let executor = HarnessMonitorClientMobileRelayCommandExecutor(
      client: client,
      now: { now }
    )
    let target = MobileCommandTarget(
      stationID: "station-mac-studio",
      sessionID: "session-pr-review",
      targetRevision: snapshot.revision
    )

    _ = try await executor.execute(
      command(
        kind: .agentStart,
        target: target,
        payload: ["agent": "codex", "prompt": "Continue implementation"]
      ),
      snapshot: snapshot
    )
    _ = try await executor.execute(
      command(
        kind: .agentStart,
        target: target,
        payload: ["agent": "claude", "prompt": "Review the changes"]
      ),
      snapshot: snapshot
    )
    _ = try await executor.execute(
      command(
        kind: .agentStart,
        target: target,
        payload: ["agent": "acp:openrouter", "prompt": "Run model review"]
      ),
      snapshot: snapshot
    )

    let events = await client.events()
    XCTAssertEqual(
      events,
      [
        "start-agent:session-pr-review:codex:codex:Continue implementation",
        "start-agent:session-pr-review:terminal:claude:Review the changes",
        "start-agent:session-pr-review:acp:acp:openrouter:Run model review",
      ]
    )
  }

  func testAPIBackedExecutorTrimsCommandTargets() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = MobileDemoFixtures.snapshot(now: now)
    let client = RecordingMobileRelayCommandClient()
    let executor = HarnessMonitorClientMobileRelayCommandExecutor(
      client: client,
      now: { now }
    )

    _ = try await executor.execute(
      command(
        kind: .agentStop,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          agentID: " agent-codex-7 ",
          targetRevision: snapshot.revision
        )
      ),
      snapshot: snapshot
    )

    let events = await client.events()
    XCTAssertEqual(events, ["stop-agent:agent-codex-7"])
  }

  func assertExecutorRejects(
    _ command: MobileCommandRecord,
    snapshot: MobileMirrorSnapshot,
    expected: MobileRelayCommandExecutionError,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    let client = RecordingMobileRelayCommandClient()
    let executor = HarnessMonitorClientMobileRelayCommandExecutor(
      client: client,
      now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    do {
      _ = try await executor.execute(command, snapshot: snapshot)
      XCTFail("Malformed command should fail before dispatch.", file: file, line: line)
    } catch {
      XCTAssertEqual(error as? MobileRelayCommandExecutionError, expected, file: file, line: line)
    }

    let events = await client.events()
    XCTAssertEqual(events, [], file: file, line: line)
  }
}
