import Testing

@testable import HarnessMonitorKit

@Suite("OpenAnything collapsed traversal")
struct OpenAnythingCollapsedTraversalTests {
  @Test("Collapsed traversal skips sections without filtering results")
  func collapsedTraversalSkipsSectionsWithoutFilteringResults() {
    let results = Self.results
    let collapsedSections: Set<String> = [OpenAnythingDomain.windows.rawValue]

    #expect(results.hitCount(excludingCollapsedSections: collapsedSections) == 2)
    #expect(results.sectionCount(excludingCollapsedSections: collapsedSections) == 2)
    #expect(!results.hasExactlyOneHit(excludingCollapsedSections: collapsedSections))
    #expect(
      results.hitID(
        movingFrom: "action.refresh",
        by: 1,
        excludingCollapsedSections: collapsedSections
      ) == "session.alpha"
    )
    #expect(
      results.firstHitIDInVisibleSection(
        movingFrom: "action.refresh",
        bySection: 1,
        excludingCollapsedSections: collapsedSections
      ) == "session.alpha"
    )
    #expect(
      results.firstHitIDInVisibleSection(
        at: 1,
        excludingCollapsedSections: collapsedSections
      ) == "session.alpha"
    )
  }

  private static var results: OpenAnythingResults {
    OpenAnythingResults(
      query: "",
      sections: [
        OpenAnythingSection(domain: .actions, hits: [hit(id: "action.refresh", domain: .actions)]),
        OpenAnythingSection(
          domain: .windows, hits: [hit(id: "window.dashboard", domain: .windows)]),
        OpenAnythingSection(domain: .sessions, hits: [hit(id: "session.alpha", domain: .sessions)]),
      ]
    )
  }

  private static func hit(id: String, domain: OpenAnythingDomain) -> OpenAnythingHit {
    OpenAnythingHit(
      record: OpenAnythingRecord(
        id: id,
        domain: domain,
        target: .action(.refresh),
        title: id
      ),
      highlights: .empty,
      score: 0
    )
  }
}
