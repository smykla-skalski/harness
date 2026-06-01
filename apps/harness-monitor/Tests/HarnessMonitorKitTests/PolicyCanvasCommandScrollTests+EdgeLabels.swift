import Testing

extension PolicyCanvasCommandScrollTests {
  @Test("edge labels remain text-rendered at far zoom")
  func edgeLabelsRemainTextRenderedAtFarZoom() throws {
    let edgeLayerSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasEdgeLayers.swift"
    )
    let labelLayerSource = try #require(
      edgeLayerSource.components(separatedBy: "struct PolicyCanvasEdgeLabelLayer: View {").last
    )

    #expect(labelLayerSource.contains("Text(edge.label)"))
    #expect(!labelLayerSource.contains("labelCollapseThreshold"))
    #expect(!labelLayerSource.contains("let collapsed = viewModel.zoom"))
    #expect(!labelLayerSource.contains("Circle()"))
  }
}
