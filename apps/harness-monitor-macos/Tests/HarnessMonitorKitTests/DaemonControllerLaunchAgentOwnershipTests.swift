import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("DaemonController managed launch-agent ownership")
struct DaemonControllerLaunchAgentOwnershipTests {
  private static let registeredAt = Date(timeIntervalSince1970: 1_777_881_172)
  private static let executablePath =
    "/Applications/Harness Monitor.app/Contents/MacOS/Harness Monitor"

  @Test("No owner record resolves to .unowned")
  func unownedWhenOwnerAbsent() {
    let decision = DaemonController.decideManagedLaunchAgentOwnership(
      owner: nil,
      selfPid: 100,
      liveness: { _ in .alive(executablePath: nil) }
    )
    #expect(decision == .unowned)
  }

  @Test("Owner record matching the current PID resolves to .ownedBySelf")
  func ownedBySelfWhenPidMatches() {
    let owner = ManagedLaunchAgentOwner(
      pid: 4242,
      executablePath: Self.executablePath,
      registeredAt: Self.registeredAt
    )
    let decision = DaemonController.decideManagedLaunchAgentOwnership(
      owner: owner,
      selfPid: 4242,
      liveness: { _ in
        Issue.record("Liveness probe must not be consulted when the recorded PID is self.")
        return .dead
      }
    )
    #expect(decision == .ownedBySelf)
  }

  @Test("Live sibling with matching executable path resolves to .ownedByLiveSibling")
  func ownedByLiveSiblingWhenExecutablePathMatches() {
    let owner = ManagedLaunchAgentOwner(
      pid: 9001,
      executablePath: Self.executablePath,
      registeredAt: Self.registeredAt
    )
    let decision = DaemonController.decideManagedLaunchAgentOwnership(
      owner: owner,
      selfPid: 4242,
      liveness: { pid in
        #expect(pid == 9001)
        return .alive(executablePath: Self.executablePath)
      }
    )
    #expect(decision == .ownedByLiveSibling(owner))
  }

  @Test("Live sibling with no resolvable executable path still resolves to .ownedByLiveSibling")
  func ownedByLiveSiblingWhenExecutablePathUnknown() {
    let owner = ManagedLaunchAgentOwner(
      pid: 9001,
      executablePath: Self.executablePath,
      registeredAt: Self.registeredAt
    )
    let decision = DaemonController.decideManagedLaunchAgentOwnership(
      owner: owner,
      selfPid: 4242,
      liveness: { _ in .alive(executablePath: nil) }
    )
    #expect(decision == .ownedByLiveSibling(owner))
  }

  @Test("Recycled PID with mismatched executable path resolves to .staleOwnership")
  func staleOwnershipWhenRecycledPidPointsAtUnrelatedExecutable() {
    let owner = ManagedLaunchAgentOwner(
      pid: 9001,
      executablePath: Self.executablePath,
      registeredAt: Self.registeredAt
    )
    let decision = DaemonController.decideManagedLaunchAgentOwnership(
      owner: owner,
      selfPid: 4242,
      liveness: { _ in .alive(executablePath: "/usr/bin/login") }
    )
    #expect(decision == .staleOwnership(owner))
  }

  @Test("Dead recorded PID resolves to .staleOwnership")
  func staleOwnershipWhenRecordedPidIsDead() {
    let owner = ManagedLaunchAgentOwner(
      pid: 9001,
      executablePath: Self.executablePath,
      registeredAt: Self.registeredAt
    )
    let decision = DaemonController.decideManagedLaunchAgentOwnership(
      owner: owner,
      selfPid: 4242,
      liveness: { _ in .dead }
    )
    #expect(decision == .staleOwnership(owner))
  }

  @Test("ManagedLaunchAgentOwner round-trips through JSON with iso8601 dates")
  func managedLaunchAgentOwnerRoundTripsThroughJSON() throws {
    let original = ManagedLaunchAgentOwner(
      pid: 1234,
      executablePath: Self.executablePath,
      registeredAt: Date(timeIntervalSince1970: 1_777_881_172)
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let data = try encoder.encode(original)
    let decoded = try decoder.decode(ManagedLaunchAgentOwner.self, from: data)
    #expect(decoded == original)
    #expect(decoded.version == ManagedLaunchAgentOwner.currentVersion)
  }
}
