import Testing

@testable import HarnessMonitorKit

@Suite("AgentTuiRuntime")
struct AgentTuiRuntimeTests {
  @Test("vibe raw value is vibe")
  func vibeRawValue() {
    #expect(AgentTuiRuntime.vibe.rawValue == "vibe")
  }

  @Test("vibe title is Vibe")
  func vibeTitle() {
    #expect(AgentTuiRuntime.vibe.title == "Vibe")
  }

  @Test("allCases includes vibe")
  func allCasesIncludesVibe() {
    #expect(AgentTuiRuntime.allCases.contains(.vibe))
  }
}
