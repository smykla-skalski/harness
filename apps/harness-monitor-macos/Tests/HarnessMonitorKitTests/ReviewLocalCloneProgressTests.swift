import Foundation
import Testing

@testable import HarnessMonitorKit

struct DependencyUpdateLocalCloneProgressTests {
  @Test
  func decodesStartedPayloadFromDaemonWireShape() throws {
    let wire = """
      {
        "kind": "started",
        "repo_full_name": "owner/repo",
        "operation": "clone"
      }
      """
    let payload = try DependencyUpdateLocalCloneProgress.snakeCaseDecoder().decode(
      DependencyUpdateLocalCloneProgress.self,
      from: Data(wire.utf8)
    )
    #expect(payload.kind == .started)
    #expect(payload.repoFullName == "owner/repo")
    #expect(payload.operation == .clone)
    #expect(payload.durationMillis == nil)
    #expect(payload.message == nil)
  }

  @Test
  func decodesCompletedPayloadWithDurationMillis() throws {
    let wire = """
      {
        "kind": "completed",
        "repo_full_name": "owner/repo",
        "operation": "fetch",
        "duration_millis": 1234
      }
      """
    let payload = try DependencyUpdateLocalCloneProgress.snakeCaseDecoder().decode(
      DependencyUpdateLocalCloneProgress.self,
      from: Data(wire.utf8)
    )
    #expect(payload.kind == .completed)
    #expect(payload.operation == .fetch)
    #expect(payload.durationMillis == 1234)
  }

  @Test
  func decodesFailedPayloadWithMessage() throws {
    let wire = """
      {
        "kind": "failed",
        "repo_full_name": "owner/repo",
        "operation": "clone",
        "message": "auth denied"
      }
      """
    let payload = try DependencyUpdateLocalCloneProgress.snakeCaseDecoder().decode(
      DependencyUpdateLocalCloneProgress.self,
      from: Data(wire.utf8)
    )
    #expect(payload.kind == .failed)
    #expect(payload.message == "auth denied")
  }

  @Test
  func operationPresentLabelMatchesUserFacingCopy() {
    #expect(DependencyUpdateLocalCloneProgress.Operation.clone.presentLabel == "Cloning")
    #expect(DependencyUpdateLocalCloneProgress.Operation.fetch.presentLabel == "Fetching")
  }

  @Test
  func operationLabelEnumRoundTripsViaDecoder() throws {
    let wire = """
      {
        "kind": "started",
        "repo_full_name": "owner/repo",
        "operation": "fetch"
      }
      """
    let payload = try DependencyUpdateLocalCloneProgress.snakeCaseDecoder().decode(
      DependencyUpdateLocalCloneProgress.self,
      from: Data(wire.utf8)
    )
    #expect(payload.operation == .fetch)
    #expect(payload.operation.presentLabel == "Fetching")
  }

  @Test
  func daemonPushEventDecodesLocalCloneProgressGlobalEvent() throws {
    let payloadJSON: [String: Any] = [
      "kind": "started",
      "repo_full_name": "owner/repo",
      "operation": "clone",
    ]
    let payloadData = try JSONSerialization.data(withJSONObject: payloadJSON)
    let payload = try JSONDecoder().decode(JSONValue.self, from: payloadData)
    let streamEvent = StreamEvent(
      event: "dependency_updates_local_clone_progress",
      recordedAt: "2026-05-22T12:00:00Z",
      sessionId: nil,
      payload: payload
    )
    let pushEvent = try DaemonPushEvent(streamEvent: streamEvent)
    switch pushEvent.kind {
    case .dependencyUpdatesLocalCloneProgress(let progress):
      #expect(progress.repoFullName == "owner/repo")
      #expect(progress.kind == .started)
    default:
      Issue.record("expected dependencyUpdatesLocalCloneProgress, got \(pushEvent.kind)")
    }
  }
}
