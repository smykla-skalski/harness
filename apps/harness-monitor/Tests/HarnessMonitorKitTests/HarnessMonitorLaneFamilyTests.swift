import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor lane family")
struct HarnessMonitorLaneFamilyTests {
  @Test("Explicit lane yields that lane family")
  func explicitLaneYieldsLaneFamily() {
    #expect(HarnessMonitorLaneFamily.from(lane: "agent-abc-123") == .lane("agent-abc-123"))
    #expect(HarnessMonitorLaneFamily.from(lane: "bartsmykla") == .lane("bartsmykla"))
  }

  @Test("Empty lane yields unscoped family")
  func emptyLaneIsUnscoped() {
    #expect(HarnessMonitorLaneFamily.from(lane: nil) == .unscoped)
    #expect(HarnessMonitorLaneFamily.from(lane: "") == .unscoped)
  }

  @Test("Path with runtime-lanes segment classifies as that lane")
  func pathClassification() {
    let agentPath =
      "/Users/me/Library/Group Containers/Q/runtime-lanes/agent-uuid/harness/daemon"
    let unscopedPath =
      "/Users/me/Library/Group Containers/Q/harness/daemon"
    let namedUserPath =
      "/Users/me/Library/Group Containers/Q/runtime-lanes/bartsmykla/harness/daemon"
    #expect(HarnessMonitorLaneFamily.from(rootPath: agentPath) == .lane("agent-uuid"))
    #expect(HarnessMonitorLaneFamily.from(rootPath: unscopedPath) == .unscoped)
    #expect(HarnessMonitorLaneFamily.from(rootPath: namedUserPath) == .lane("bartsmykla"))
  }

  @Test("Compatibility requires matching lane families")
  func compatibilityMatrix() {
    let laneX: HarnessMonitorLaneFamily = .lane("x")
    let laneY: HarnessMonitorLaneFamily = .lane("y")
    let unscoped: HarnessMonitorLaneFamily = .unscoped

    #expect(HarnessMonitorLaneFamily.compatible(laneX, laneX))
    #expect(HarnessMonitorLaneFamily.compatible(unscoped, unscoped))
    #expect(!HarnessMonitorLaneFamily.compatible(laneX, laneY))
    #expect(!HarnessMonitorLaneFamily.compatible(laneX, unscoped))
    #expect(!HarnessMonitorLaneFamily.compatible(unscoped, laneX))
  }

  @Test("Own family resolves from runtime lane env")
  func ownFamilyFromRuntimeLaneEnv() {
    let environment = HarnessMonitorEnvironment(
      values: [HarnessMonitorRuntimeLane.environmentKey: "agent-abc"],
      homeDirectory: URL(fileURLWithPath: "/Users/me", isDirectory: true)
    )
    #expect(HarnessMonitorPaths.ownLaneFamily(using: environment) == .lane("agent-abc"))
  }

  @Test("Own family is unscoped when no lane is set")
  func ownFamilyUnscoped() {
    let environment = HarnessMonitorEnvironment(
      values: [:],
      homeDirectory: URL(fileURLWithPath: "/Users/me", isDirectory: true)
    )
    #expect(HarnessMonitorPaths.ownLaneFamily(using: environment) == .unscoped)
  }
}
