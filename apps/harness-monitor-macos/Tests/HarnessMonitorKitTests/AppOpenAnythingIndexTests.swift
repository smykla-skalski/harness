import Testing

@testable import HarnessMonitorKit

@Suite("AppOpenAnything index")
struct AppOpenAnythingIndexTests {
  @Test("Empty query returns no sections")
  func emptyQueryReturnsNoSections() async {
    let index = OpenAnythingIndex()
    await index.replace(records: [Self.record(id: "settings", domain: .settings, title: "General")])

    let results = await index.search(query: "   \n\t  ")

    #expect(results == .empty)
  }

  @Test("Results are grouped by domain order")
  func resultsAreGroupedByDomainOrder() async {
    let index = OpenAnythingIndex()
    await index.replace(records: [
      Self.record(id: "session", domain: .sessions, title: "Alpha Session"),
      Self.record(id: "action", domain: .actions, title: "Alpha Action"),
      Self.record(id: "settings", domain: .settings, title: "Alpha Settings"),
    ])

    let results = await index.search(query: "alpha")

    #expect(results.sections.map(\.domain) == [.actions, .settings, .sessions])
  }

  @Test("Title prefix match outranks body-only match")
  func titlePrefixMatchOutranksBodyOnlyMatch() async {
    let index = OpenAnythingIndex()
    await index.replace(records: [
      Self.record(
        id: "body",
        domain: .sessions,
        title: "Worker Session",
        searchBodyParts: ["alpha"]
      ),
      Self.record(id: "title", domain: .sessions, title: "Alpha Session"),
    ])

    let results = await index.search(query: "alpha")

    #expect(results.sections.first?.hits.map(\.id).first == "title")
  }

  @Test("Single-edit typo still matches and carries highlights")
  func singleEditTypoStillMatches() async {
    let index = OpenAnythingIndex()
    await index.replace(records: [
      Self.record(id: "dashboard", domain: .windows, title: "Dashboard")
    ])

    let results = await index.search(query: "dashbord")
    let hit = results.sections.first?.hits.first

    #expect(hit?.id == "dashboard")
    #expect(hit?.highlights.title.isEmpty == false)
  }

  @Test("Replacing corpus removes stale records")
  func replacingCorpusRemovesStaleRecords() async {
    let index = OpenAnythingIndex()
    await index.replace(records: [
      Self.record(id: "old", domain: .sessions, title: "Alpha Old")
    ])
    await index.replace(records: [
      Self.record(id: "new", domain: .sessions, title: "Alpha New")
    ])

    let results = await index.search(query: "alpha")

    #expect(await index.recordCount() == 1)
    #expect(results.sections.first?.hits.map(\.id) == ["new"])
  }

  private static func record(
    id: String,
    domain: OpenAnythingDomain,
    title: String,
    subtitle: String? = nil,
    searchBodyParts: [String?] = []
  ) -> OpenAnythingRecord {
    OpenAnythingRecord(
      id: id,
      domain: domain,
      target: .action(.refresh),
      title: title,
      subtitle: subtitle,
      searchBodyParts: searchBodyParts
    )
  }
}
