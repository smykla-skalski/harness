import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor profile family")
struct HarnessMonitorProfileFamilyTests {
  @Test("Agent prefix yields agent family with id")
  func agentPrefixYieldsAgentFamily() {
    #expect(
      HarnessMonitorProfileFamily.from(profile: "agent-abc-123")
        == .agent("abc-123")
    )
  }

  @Test("Empty or non-agent profile yields non-agent family")
  func nonAgentProfile() {
    #expect(HarnessMonitorProfileFamily.from(profile: nil) == .nonAgent)
    #expect(HarnessMonitorProfileFamily.from(profile: "") == .nonAgent)
    #expect(HarnessMonitorProfileFamily.from(profile: "claude-main") == .nonAgent)
    #expect(HarnessMonitorProfileFamily.from(profile: "bartsmykla") == .nonAgent)
  }

  @Test("Path with runtime-profiles segment classifies as that profile")
  func pathClassification() {
    let agentPath =
      "/Users/me/Library/Group Containers/Q/runtime-profiles/agent-uuid/harness/daemon"
    let userPath =
      "/Users/me/Library/Group Containers/Q/harness/daemon"
    let namedUserPath =
      "/Users/me/Library/Group Containers/Q/runtime-profiles/bartsmykla/harness/daemon"
    #expect(HarnessMonitorProfileFamily.from(rootPath: agentPath) == .agent("uuid"))
    #expect(HarnessMonitorProfileFamily.from(rootPath: userPath) == .nonAgent)
    #expect(HarnessMonitorProfileFamily.from(rootPath: namedUserPath) == .nonAgent)
  }

  @Test("Compatibility matches Rust families_compatible rules")
  func compatibilityMatrix() {
    let agentX: HarnessMonitorProfileFamily = .agent("x")
    let agentY: HarnessMonitorProfileFamily = .agent("y")
    let nonAgent: HarnessMonitorProfileFamily = .nonAgent

    #expect(HarnessMonitorProfileFamily.compatible(agentX, agentX))
    #expect(HarnessMonitorProfileFamily.compatible(nonAgent, nonAgent))
    #expect(!HarnessMonitorProfileFamily.compatible(agentX, agentY))
    #expect(!HarnessMonitorProfileFamily.compatible(agentX, nonAgent))
    #expect(!HarnessMonitorProfileFamily.compatible(nonAgent, agentX))
  }

  @Test("Own family infers agent profile from bundle path")
  func ownFamilyFromBundlePath() {
    let environment = HarnessMonitorEnvironment(
      values: [:],
      homeDirectory: URL(fileURLWithPath: "/Users/me", isDirectory: true),
      bundleURL: URL(
        fileURLWithPath:
          "/repo/xcode-derived/profiles/agent-abc/Build/Products/Debug/Harness Monitor.app",
        isDirectory: true
      )
    )
    #expect(HarnessMonitorPaths.ownProfileFamily(using: environment) == .agent("abc"))
  }

  @Test("Own family is non-agent when no profile inferred")
  func ownFamilyNonAgent() {
    let environment = HarnessMonitorEnvironment(
      values: [:],
      homeDirectory: URL(fileURLWithPath: "/Users/me", isDirectory: true)
    )
    #expect(HarnessMonitorPaths.ownProfileFamily(using: environment) == .nonAgent)
  }
}
