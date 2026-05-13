import Testing

extension SessionWindowFlowTests {
  @Test("Session selection persistence keeps SceneStorage writes idempotent")
  func sessionSelectionPersistenceAvoidsDuplicateSceneStorageWrites() throws {
    let source = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+SelectionPersistence.swift"
    )

    #expect(
      source.contains(
        "updatePersistedSelection(route: targetRoute, "
          + "decisionID: targetDecisionID)"
      )
    )
    #expect(source.contains("if persistedRoute != route {"))
    #expect(source.contains("if persistedDecisionID != decisionID {"))
    #expect(source.contains("if !persistedDecisionQuery.isEmpty {"))
  }
}
