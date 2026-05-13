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
}
