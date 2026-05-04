import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Send update action")
struct SendUpdateActionTests {
  @Test("Inject context maps to inject_context raw command")
  func injectContextRawCommand() {
    #expect(SendUpdateAction.injectContext.rawCommand == "inject_context")
  }

  @Test("Custom raw command is empty so the user must type one")
  func customRawCommandIsEmpty() {
    #expect(SendUpdateAction.custom.rawCommand == "")
  }

  @Test("Human labels are user-facing strings, not enum case names")
  func humanLabels() {
    #expect(SendUpdateAction.injectContext.humanLabel == "Inject context")
    #expect(SendUpdateAction.custom.humanLabel == "Other…")
  }

  @Test("All labeled cases is a stable, ordered list with no duplicates")
  func allLabeledCases() {
    let cases = SendUpdateAction.allLabeledCases
    #expect(cases == [.injectContext, .custom])
    #expect(Set(cases).count == cases.count)
  }
}
