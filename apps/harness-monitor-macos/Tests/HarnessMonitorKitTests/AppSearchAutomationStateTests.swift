import Testing

@testable import HarnessMonitorUIPreviewable

@MainActor
struct AppSearchAutomationStateTests {
  @Test("Automation commands advance generations and preserve search intent")
  func commandsAdvanceGenerationsAndPreserveSearchIntent() {
    let state = AppSearchAutomationState()

    #expect(state.command == .idle)

    state.present(query: "worker")
    let first = state.command
    #expect(first.generation == 1)
    #expect(first.query == "worker")
    #expect(first.isPresented)
    #expect(first.isFocused)

    state.present(query: "worker")
    let repeated = state.command
    #expect(repeated.generation == 2)
    #expect(repeated.query == "worker")
    #expect(repeated.isPresented)
    #expect(repeated.isFocused)

    state.dismiss()
    #expect(state.command.generation == 3)
    #expect(state.command.query.isEmpty)
    #expect(!state.command.isPresented)
    #expect(!state.command.isFocused)
  }
}
