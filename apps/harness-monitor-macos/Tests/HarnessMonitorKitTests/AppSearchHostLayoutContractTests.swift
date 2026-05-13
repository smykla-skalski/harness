import Testing

extension SessionWindowFlowTests {
  @Test("App search toolbar anchor stays zero-sized")
  func appSearchToolbarAnchorStaysZeroSized() throws {
    let source = try previewableSourceFile(named: "Views/Search/AppSearchHost.swift")
    let sessionHostSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+SearchHost.swift"
    )

    #expect(source.contains(".searchable("))
    #expect(source.contains(".frame(width: 0, height: 0)"))
    #expect(source.contains(".searchSuggestions"))
    #expect(!source.contains("suggestionOverlay"))
    #expect(!source.contains("AppSearchSuggestionsView"))
    #expect(source.contains(".allowsHitTesting(false)"))
    #expect(!source.contains(".frame(maxWidth: .infinity, maxHeight: .infinity"))
    #expect(!sessionHostSource.contains(".frame(maxWidth: .infinity, maxHeight: .infinity"))
  }

  @Test("Session search waits until startup load enables the toolbar field")
  func sessionSearchDefersToolbarFieldUntilStartupSettles() throws {
    let hostSource = try previewableSourceFile(named: "Views/Search/AppSearchHost.swift")
    let sessionWindowSource = try previewableSourceFile(named: "Views/Sessions/SessionWindowView.swift")
    let sessionHostSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+SearchHost.swift"
    )
    let presentationSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+Presentation.swift"
    )

    #expect(hostSource.contains("let isEnabled: Bool"))
    #expect(hostSource.contains("guard isEnabled else {\n      return nil\n    }"))
    #expect(hostSource.contains("guard isEnabled, hasSearchQuery else {"))
    #expect(hostSource.contains("if isEnabled {"))
    #expect(
      sessionWindowSource.contains(
        "@State private var startupSearchParticipationEnabledStorage = HarnessMonitorUITestEnvironment.isEnabled"
      )
    )
    #expect(sessionWindowSource.contains("var isStartupSearchParticipationEnabled: Bool {"))
    #expect(sessionHostSource.contains("isEnabled: isStartupSearchParticipationEnabled"))
    #expect(presentationSource.contains("enableStartupSearchParticipation()"))
  }
}
