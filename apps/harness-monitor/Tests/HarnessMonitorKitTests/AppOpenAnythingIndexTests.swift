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

  @Test("Scoped search skips non-scoped domains")
  func scopedSearchSkipsNonScopedDomains() async {
    let index = OpenAnythingIndex()
    await index.replace(records: [
      Self.record(id: "action", domain: .actions, title: "Alpha Action"),
      Self.record(id: "session", domain: .sessions, title: "Alpha Session"),
    ])

    let results = await index.search(query: "alpha", scope: .sessions)

    #expect(results.sections.map(\.domain) == [.sessions])
    #expect(results.sections.flatMap(\.hits).map(\.id) == ["session"])
    #expect(results.totalCount(for: .actions) == 0)
    #expect(results.totalCount(for: .sessions) == 1)
  }

  @Test("Scoped search clears cached domain indexes after replace")
  func scopedSearchClearsDomainIndexAfterReplace() async {
    let index = OpenAnythingIndex()
    await index.replace(records: [
      Self.record(id: "session-old", domain: .sessions, title: "Alpha Session"),
      Self.record(id: "action", domain: .actions, title: "Alpha Action"),
    ])
    let first = await index.search(query: "alpha", scope: .sessions)
    #expect(first.sections.flatMap(\.hits).map(\.id) == ["session-old"])

    await index.replace(records: [
      Self.record(id: "session-new", domain: .sessions, title: "Beta Session"),
      Self.record(id: "action", domain: .actions, title: "Alpha Action"),
    ])
    let second = await index.search(query: "alpha", scope: .sessions)

    #expect(second.sections.isEmpty)
    #expect(second.totalCount(for: .sessions) == 0)
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

  @Test("Capped search keeps the best late match")
  func cappedSearchKeepsBestLateMatch() async {
    let index = OpenAnythingIndex()
    let bodyRecords = (0..<8).map { idx in
      Self.record(
        id: "body-\(idx)",
        domain: .sessions,
        title: "Worker \(idx)",
        searchBodyParts: ["alpha"]
      )
    }
    await index.replace(
      records: bodyRecords + [
        Self.record(id: "title", domain: .sessions, title: "Alpha Session")
      ]
    )

    let results = await index.search(query: "alpha", limitPerDomain: 1)
    let sessions = results.sections.first(where: { $0.domain == .sessions })

    #expect(sessions?.hits.map(\.id) == ["title"])
    #expect(sessions?.hits.first?.highlights.title.isEmpty == false)
    #expect(results.totalCount(for: .sessions) == 9)
  }

  @Test("Fuzzy search accepts caller-specific ordering")
  func fuzzySearchUsesCallerOrdering() throws {
    let index = try FuzzySearchIndex(
      items: [
        Self.searchItem(id: "a", title: "Alpha A"),
        Self.searchItem(id: "z", title: "Alpha Z"),
      ],
      fields: [
        FuzzySearchField.single("title", weight: 1, highlightField: .title) { $0.title }
      ]
    )

    let results = index.search("alpha") { lhs, rhs in
      lhs.item.id > rhs.item.id
    }
    let topResults = index.topResults("alpha", limit: 1) { lhs, rhs in
      lhs.item.id > rhs.item.id
    }

    #expect(results.map(\.item.id) == ["z", "a"])
    #expect(topResults.results.map(\.item.id) == ["z"])
    #expect(topResults.totalCount == 2)
    #expect(topResults.isTruncated)
    #expect(topResults.results.first?.highlights.title.isEmpty == false)
  }

  @Test("Open Anything search streams fuzzy candidates")
  func fuzzySearchStreamsCandidates() throws {
    let index = try FuzzySearchIndex(
      items: [
        Self.searchItem(id: "a", title: "Alpha A"),
        Self.searchItem(id: "b", title: "Beta B"),
      ],
      fields: [
        FuzzySearchField.single("title", weight: 1, highlightField: .title) { $0.title }
      ]
    )

    var streamedIDs: [String] = []
    index.forEachCandidate("alpha") { candidate in
      streamedIDs.append(candidate.item.id)
    }

    #expect(streamedIDs == ["a"])
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

  @Test("Suggested results keep empty palette useful and grouped")
  func suggestedResultsKeepEmptyPaletteUsefulAndGrouped() async {
    let index = OpenAnythingIndex()
    await index.replace(records: [
      Self.record(id: "session", domain: .sessions, title: "Alpha Session"),
      Self.record(
        id: "action.refresh",
        domain: .actions,
        title: "Refresh",
        isSuggested: true
      ),
      Self.record(
        id: "window.dashboard",
        domain: .windows,
        title: "Dashboard",
        isSuggested: true
      ),
      Self.record(
        id: "window.diagnostics",
        domain: .windows,
        title: "Diagnostics",
        isSuggested: true
      ),
      Self.record(
        id: "settings.general",
        domain: .settings,
        title: "General",
        isSuggested: true
      ),
    ])

    let results = await index.suggestedResults(limitPerDomain: 1)

    #expect(results.query.isEmpty)
    #expect(results.sections.map(\.domain) == [.actions, .windows, .settings])
    #expect(
      results.sections.flatMap(\.hits).map(\.id) == [
        "action.refresh",
        "window.dashboard",
        "settings.general",
      ]
    )
    #expect(results.sections.flatMap(\.hits).allSatisfy { $0.highlights == .empty })

    let scoped = await index.suggestedResults(scope: .windows)

    #expect(scoped.sections.map(\.domain) == [.windows])
    #expect(
      scoped.sections.flatMap(\.hits).map(\.id) == [
        "window.dashboard",
        "window.diagnostics",
      ])
    #expect(scoped.totalCount(for: .actions) == 0)
    #expect(scoped.totalCount(for: .windows) == 2)
  }

  @Test("Result helper detects exactly one visible hit")
  func resultHelperDetectsExactlyOneVisibleHit() {
    let first = OpenAnythingHit(
      record: Self.record(id: "one", domain: .actions, title: "One"),
      highlights: .empty,
      score: 0
    )
    let second = OpenAnythingHit(
      record: Self.record(id: "two", domain: .settings, title: "Two"),
      highlights: .empty,
      score: 0
    )

    let single = OpenAnythingResults(
      query: "",
      sections: [OpenAnythingSection(domain: .actions, hits: [first])]
    )
    let multiple = OpenAnythingResults(
      query: "",
      sections: [
        OpenAnythingSection(domain: .actions, hits: [first]),
        OpenAnythingSection(domain: .settings, hits: [second]),
      ]
    )

    #expect(single.hasExactlyOneHit)
    #expect(!multiple.hasExactlyOneHit)
    #expect(!OpenAnythingResults.empty.hasExactlyOneHit)
  }

  @Test("Record search body trims and joins non-empty parts")
  func recordSearchBodyTrimsAndJoinsNonEmptyParts() {
    let record = OpenAnythingRecord(
      id: "record",
      domain: .actions,
      target: .action(.refresh),
      title: "Record",
      searchBodyParts: [" alpha ", nil, "", "\n beta\t", "gamma"]
    )

    #expect(record.searchBody == "alpha beta gamma")
  }

  private static func record(
    id: String,
    domain: OpenAnythingDomain,
    title: String,
    subtitle: String? = nil,
    isSuggested: Bool = false,
    searchBodyParts: [String?] = []
  ) -> OpenAnythingRecord {
    OpenAnythingRecord(
      id: id,
      domain: domain,
      target: .action(.refresh),
      title: title,
      subtitle: subtitle,
      isSuggested: isSuggested,
      searchBodyParts: searchBodyParts
    )
  }

  private static func searchItem(id: String, title: String) -> SearchItem {
    SearchItem(id: id, title: title)
  }

  private struct SearchItem: Sendable {
    let id: String
    let title: String
  }
}
