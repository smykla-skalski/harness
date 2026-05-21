import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard dependencies search suggestions")
struct DashboardDependenciesSearchSuggestionsTests {
  @Test("empty query yields no suggestions")
  func emptyQuery() {
    let items = [item(id: "pr-1", repository: "kong/a", number: 1, title: "Renovate one")]
    let suggestions = dashboardDependenciesSearchSuggestions(query: "  ", items: items)
    #expect(suggestions.isEmpty)
  }

  @Test("title prefix outranks substring match")
  func titlePrefixWins() {
    let prefixMatch = item(id: "pr-prefix", repository: "kong/a", number: 1, title: "Bump axios")
    let substringMatch = item(
      id: "pr-sub", repository: "kong/b", number: 2, title: "Maybe bump deps"
    )
    let suggestions = dashboardDependenciesSearchSuggestions(
      query: "bump",
      items: [substringMatch, prefixMatch]
    )
    #expect(suggestions.first?.pullRequestID == "pr-prefix")
  }

  @Test("matches repository, author, label, and number")
  func multipleFields() {
    let items = [
      item(id: "pr-repo", repository: "kong/kuma", number: 10, title: "Unrelated"),
      item(
        id: "pr-author", repository: "kong/a", number: 11, title: "Unrelated",
        authorLogin: "smykla"
      ),
      item(
        id: "pr-label", repository: "kong/b", number: 12, title: "Unrelated",
        labels: ["security"]
      ),
      item(id: "pr-number", repository: "kong/c", number: 4242, title: "Unrelated"),
    ]
    #expect(
      dashboardDependenciesSearchSuggestions(query: "kuma", items: items)
        .map(\.pullRequestID) == ["pr-repo"]
    )
    #expect(
      dashboardDependenciesSearchSuggestions(query: "smykla", items: items)
        .map(\.pullRequestID) == ["pr-author"]
    )
    #expect(
      dashboardDependenciesSearchSuggestions(query: "security", items: items)
        .map(\.pullRequestID) == ["pr-label"]
    )
    #expect(
      dashboardDependenciesSearchSuggestions(query: "#4242", items: items)
        .map(\.pullRequestID) == ["pr-number"]
    )
  }

  @Test("limit caps results")
  func limitCap() {
    let items = (0..<20).map { index in
      item(
        id: "pr-\(index)",
        repository: "kong/repo\(index)",
        number: UInt64(index + 1),
        title: "Bump dependency \(index)"
      )
    }
    let suggestions = dashboardDependenciesSearchSuggestions(
      query: "bump", items: items, limit: 5
    )
    #expect(suggestions.count == 5)
  }

  @Test("suggestion subtitle has the routing-friendly shape")
  func subtitleShape() {
    let entry = item(id: "pr-x", repository: "kong/a", number: 7, title: "Bump foo")
    let suggestions = dashboardDependenciesSearchSuggestions(query: "bump", items: [entry])
    #expect(suggestions.first?.subtitle == "kong/a#7 · @renovate[bot]")
  }

  private func item(
    id: String,
    repository: String,
    number: UInt64,
    title: String,
    authorLogin: String = "renovate[bot]",
    labels: [String] = ["dependencies"]
  ) -> DependencyUpdateItem {
    DependencyUpdateItem(
      pullRequestID: id,
      repositoryID: "repo-\(repository)",
      repository: repository,
      number: number,
      title: title,
      url: "https://github.com/\(repository)/pull/\(number)",
      authorLogin: authorLogin,
      state: .open,
      mergeable: .mergeable,
      reviewStatus: .none,
      checkStatus: .success,
      policyBlocked: false,
      isDraft: false,
      headSha: "sha-\(id)",
      labels: labels,
      additions: 1,
      deletions: 1,
      createdAt: "2026-05-01T10:00:00Z",
      updatedAt: "2026-05-01T10:00:00Z"
    )
  }
}
