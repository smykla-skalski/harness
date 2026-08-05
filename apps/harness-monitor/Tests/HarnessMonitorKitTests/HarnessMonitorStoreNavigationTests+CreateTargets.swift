import Testing

@testable import HarnessMonitorUIPreviewable

extension HarnessMonitorStoreNavigationTests {
  @Test("Legacy create history restores generic Dashboard creation routes")
  func legacyCreateHistoryAvoidsFakeExactTargets() async throws {
    let store = try await makeNavigationStore()
    let history = GlobalWindowNavigationHistory(store: store)

    #expect(
      history.dashboardSelection(
        for: .create(SessionCreateDraft(kind: .task, sessionID: "session-1")),
        sessionID: "session-1"
      ) == .route(.taskBoard)
    )
    #expect(
      history.dashboardSelection(
        for: .create(SessionCreateDraft(kind: .agent, sessionID: "session-1")),
        sessionID: "session-1"
      ) == .route(.agents)
    )
  }
}
