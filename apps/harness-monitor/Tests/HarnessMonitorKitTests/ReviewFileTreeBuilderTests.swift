import Testing

@testable import HarnessMonitorKit

struct ReviewFileTreeBuilderTests {
  @Test("builder normalizes empty path segments")
  func builderNormalizesEmptyPathSegments() {
    let nodes = ReviewFileTreeBuilder.build(
      files: [
        reviewFile(path: "/Sources//App/main.swift"),
        reviewFile(path: "Docs/"),
      ]
    )

    #expect(nodes.map(\.name) == ["Sources", "Docs"])
    #expect(nodes.first?.fullPath == "Sources")
    #expect(nodes.first?.children.map(\.name) == ["App"])
    #expect(nodes.first?.children.first?.fullPath == "Sources/App")
    #expect(
      nodes.first?.children.first?.children.map(\.fullPath) == [
        "Sources/App/main.swift"
      ])
  }
}

private func reviewFile(path: String) -> ReviewFile {
  ReviewFile(
    path: path,
    changeType: .modified,
    additions: 0,
    deletions: 0,
    viewerViewedState: .unviewed
  )
}
