import Testing

extension SessionWindowFlowTests {
  @Test("App search toolbar anchor stays zero-sized")
  func appSearchToolbarAnchorStaysZeroSized() throws {
    let source = try previewableSourceFile(named: "Views/Search/AppSearchHost.swift")

    #expect(source.contains(".searchable("))
    #expect(source.contains(".frame(width: 0, height: 0)"))
    #expect(!source.contains(".frame(maxWidth: .infinity, maxHeight: .infinity"))
  }
}
