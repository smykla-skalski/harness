import Foundation
import Testing

@Suite("Policy canvas dense overlay performance")
struct PolicyCanvasDenseOverlayPerformanceTests {
  @Test("dense edge layer caches AppKit paths outside dirty-rect redraws")
  func denseEdgeLayerCachesRenderedPaths() throws {
    let source = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasDenseEdgeDrawingSurface.swift"
    )
    let drawFunction = try sourceFunction(
      named: "private func draw(_ item: PolicyCanvasDenseEdgeRenderedItem)",
      in: source
    )
    let renderedItemsAssignment =
      "renderedItems = items.map(PolicyCanvasDenseEdgeRenderedItem.init(item:))"

    #expect(source.contains("private struct PolicyCanvasDenseEdgeRenderedItem"))
    #expect(source.contains("private var renderedItems: [PolicyCanvasDenseEdgeRenderedItem] = []"))
    #expect(source.contains(renderedItemsAssignment))
    #expect(drawFunction.contains("for path in item.paths"))
    #expect(!drawFunction.contains("policyCanvasVisibleEdgeSubroutes("))
    #expect(!drawFunction.contains("policyCanvasAppKitEdgePath(points:"))
    #expect(!drawFunction.contains("policyCanvasDenseEdgeArrowheadPath(route:"))
  }

  @Test("solid strokes clear stale dash state on cached paths")
  func solidStrokesClearDashStateOnCachedPaths() throws {
    let source = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasAppKitDrawingSupport.swift"
    )
    let strokeFunction = try sourceFunction(
      named: "func policyCanvasStroke(",
      in: source
    )

    #expect(strokeFunction.contains("path.setLineDash(nil, count: 0, phase: 0)"))
  }

  private func previewableSourceFile(named path: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(path)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }

  private func sourceFunction(named marker: String, in source: String) throws -> String {
    guard let start = source.range(of: marker) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let remaining = source[start.upperBound...]
    let endMarkers = ["\nfunc ", "\nprivate func ", "\n  private func ", "\n  func "]
    let end =
      endMarkers
      .compactMap { remaining.range(of: $0)?.lowerBound }
      .min()
      ?? source.endIndex
    return String(source[start.lowerBound..<end])
  }
}
