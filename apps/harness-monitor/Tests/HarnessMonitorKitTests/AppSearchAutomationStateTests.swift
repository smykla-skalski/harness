import Testing

@testable import HarnessMonitorUIPreviewable

@MainActor
struct AppSearchAutomationStateTests {
  @Test("Automation commands advance generations and preserve search intent")
  func commandsAdvanceGenerationsAndPreserveSearchIntent() {
    let state = AppSearchAutomationState()

    #expect(state.command == .idle)

    state.present(query: "worker")
    #expect(
      state.command
        == AppSearchAutomationCommand(
          generation: 1,
          query: "worker",
          isPresented: true
        )
    )

    state.present(query: "worker")
    #expect(
      state.command
        == AppSearchAutomationCommand(
          generation: 2,
          query: "worker",
          isPresented: true
        )
    )

    state.dismiss()
    #expect(
      state.command
        == AppSearchAutomationCommand(
          generation: 3,
          query: "",
          isPresented: false
        )
    )
  }
}
