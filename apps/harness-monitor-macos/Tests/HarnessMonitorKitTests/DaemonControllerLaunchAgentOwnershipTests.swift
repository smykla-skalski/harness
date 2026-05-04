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
      registeredAt: Date(timeIntervalSince1970: 1_777_881_172),
      bootSessionUUID: "11111111-2222-3333-4444-555555555555"
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let data = try encoder.encode(original)
    let decoded = try decoder.decode(ManagedLaunchAgentOwner.self, from: data)
    #expect(decoded == original)
    #expect(decoded.version == ManagedLaunchAgentOwner.currentVersion)
    #expect(decoded.bootSessionUUID == "11111111-2222-3333-4444-555555555555")
  }

  @Test(
    "Owner with matching bootSessionUUID resolves to .ownedByLiveSibling when sibling is alive"
  )
  func ownedByLiveSiblingWhenBootSessionUUIDMatches() {
    let owner = ManagedLaunchAgentOwner(
      pid: 9001,
      executablePath: Self.executablePath,
      registeredAt: Self.registeredAt,
      bootSessionUUID: "boot-uuid-A"
    )
    let decision = DaemonController.decideManagedLaunchAgentOwnership(
      owner: owner,
      selfPid: 4242,
      liveness: { _ in .alive(executablePath: Self.executablePath) },
      currentBootSessionUUID: "boot-uuid-A"
    )
    #expect(decision == .ownedByLiveSibling(owner))
  }

  @Test("Owner with different bootSessionUUID resolves to .staleOwnership across reboot")
  func staleOwnershipWhenBootSessionUUIDDiffers() {
    let owner = ManagedLaunchAgentOwner(
      pid: 9001,
      executablePath: Self.executablePath,
      registeredAt: Self.registeredAt,
      bootSessionUUID: "boot-uuid-PREVIOUS"
    )
    let decision = DaemonController.decideManagedLaunchAgentOwnership(
      owner: owner,
      selfPid: 4242,
      liveness: { _ in
        Issue.record("Liveness probe must not be consulted when boot UUID rejects across-boot.")
        return .alive(executablePath: nil)
      },
      currentBootSessionUUID: "boot-uuid-CURRENT"
    )
    #expect(decision == .staleOwnership(owner))
  }

  @Test(
    "Schema-v1 owner (nil bootSessionUUID) resolves to .staleOwnership for v2-aware reader"
  )
  func staleOwnershipForLegacySchemaWhenCurrentBootUUIDKnown() {
    let owner = ManagedLaunchAgentOwner(
      pid: 9001,
      executablePath: Self.executablePath,
      registeredAt: Self.registeredAt,
      bootSessionUUID: nil
    )
    let decision = DaemonController.decideManagedLaunchAgentOwnership(
      owner: owner,
      selfPid: 4242,
      liveness: { _ in
        Issue.record("Liveness probe must not be consulted for legacy v1 marker.")
        return .alive(executablePath: nil)
      },
      currentBootSessionUUID: "boot-uuid-CURRENT"
    )
    #expect(decision == .staleOwnership(owner))
  }

  @Test(
    "Schema-v1 owner falls through to pid/exec corroboration when current bootSessionUUID is nil"
  )
  func legacySchemaUsesPidExecPathWhenCurrentBootUUIDUnknown() {
    let owner = ManagedLaunchAgentOwner(
      pid: 9001,
      executablePath: Self.executablePath,
      registeredAt: Self.registeredAt,
      bootSessionUUID: nil
    )
    let decision = DaemonController.decideManagedLaunchAgentOwnership(
      owner: owner,
      selfPid: 4242,
      liveness: { _ in .alive(executablePath: Self.executablePath) },
      currentBootSessionUUID: nil
    )
    #expect(decision == .ownedByLiveSibling(owner))
  }

  @Test("Legacy v1 JSON (no bootSessionUUID field) decodes with bootSessionUUID == nil")
  func legacyV1JSONDecodesIntoCurrentSchemaWithNilBootUUID() throws {
    let legacyJSON = #"""
      {
        "executablePath": "\#(Self.executablePath)",
        "pid": 9001,
        "registeredAt": "2026-05-04T09:12:52Z",
        "version": 1
      }
      """#
    let data = Data(legacyJSON.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(ManagedLaunchAgentOwner.self, from: data)
    #expect(decoded.version == 1)
    #expect(decoded.bootSessionUUID == nil)
    #expect(decoded.pid == 9001)
  }

  @Test("Constructor that omits bootSessionUUID stamps version 1 (legacy emit path)")
  func constructorWithoutBootSessionUUIDStampsLegacyVersion() {
    let owner = ManagedLaunchAgentOwner(
      pid: 1,
      executablePath: Self.executablePath,
      registeredAt: Self.registeredAt
    )
    #expect(owner.version == 1)
    #expect(owner.bootSessionUUID == nil)
  }

  @Test("Constructor that supplies bootSessionUUID stamps the current schema version")
  func constructorWithBootSessionUUIDStampsCurrentVersion() {
    let owner = ManagedLaunchAgentOwner(
      pid: 1,
      executablePath: Self.executablePath,
      registeredAt: Self.registeredAt,
      bootSessionUUID: "boot-uuid"
    )
    #expect(owner.version == ManagedLaunchAgentOwner.currentVersion)
    #expect(owner.bootSessionUUID == "boot-uuid")
  }
}
