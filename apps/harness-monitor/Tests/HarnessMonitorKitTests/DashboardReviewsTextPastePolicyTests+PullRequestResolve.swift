import HarnessMonitorKit
import Testing

@testable import HarnessMonitorUIPreviewable

extension DashboardReviewsTextPastePolicyTests {
  @Test("Full PR URL miss resolves by PR reference without repository refresh")
  func fullPRURLMissResolvesByPRReferenceWithoutRepositoryRefresh() async {
    await ReviewPullRequestExtractionService.resetNumberMemoryForTesting()
    let item = Self.reviewItem(repository: "example-org/example-repo", number: 42)
    var fetchedReferences: [ReviewsPullRequestReference] = []
    var fetchedRepositories: [String] = []

    let result = await ReviewPullRequestExtractionService.resolve(
      rows: [Self.resolvedRow(index: 0, item: item)],
      context: ReviewPullRequestExtractionContext(
        currentItems: [],
        configuredRepositories: ["example-org/example-repo"],
        activeReviewsRepository: nil,
        configuration: ReviewPullRequestExtractionConfiguration(),
        fetchPullRequests: { references in
          fetchedReferences = references
          return [item]
        },
        fetchRepositories: { repositories in
          fetchedRepositories = repositories
          return []
        }
      )
    )

    #expect(
      fetchedReferences == [
        ReviewsPullRequestReference(repository: "example-org/example-repo", number: 42)
      ]
    )
    #expect(fetchedRepositories.isEmpty)
    #expect(result.matchedItems.map(\.pullRequestID) == ["example-org/example-repo#42"])
    #expect(result.outputText == "https://github.com/example-org/example-repo/pull/42")
  }

  @Test("Full PR URL miss does not fall back to repository refresh when PR resolver misses")
  func fullPRURLMissDoesNotFallBackToRepositoryRefreshWhenPRResolverMisses() async {
    await ReviewPullRequestExtractionService.resetNumberMemoryForTesting()
    let item = Self.reviewItem(repository: "example-org/example-repo", number: 43)
    var fetchedReferences: [ReviewsPullRequestReference] = []
    var fetchedRepositories: [String] = []

    let result = await ReviewPullRequestExtractionService.resolve(
      rows: [Self.resolvedRow(index: 0, item: item)],
      context: ReviewPullRequestExtractionContext(
        currentItems: [],
        configuredRepositories: ["example-org/example-repo"],
        activeReviewsRepository: nil,
        configuration: ReviewPullRequestExtractionConfiguration(),
        fetchPullRequests: { references in
          fetchedReferences = references
          return []
        },
        fetchRepositories: { repositories in
          fetchedRepositories = repositories
          return []
        }
      )
    )

    #expect(
      fetchedReferences == [
        ReviewsPullRequestReference(repository: "example-org/example-repo", number: 43)
      ]
    )
    #expect(fetchedRepositories.isEmpty)
    #expect(result.matchedItems.isEmpty)
    #expect(
      result.missingRows.map(\.row.reference.displayText) == ["example-org/example-repo#43"]
    )
  }
}
