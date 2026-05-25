import Foundation

extension PreviewHarnessClient {
  public static let previewGitHubApiDiagnostics = GitHubApiDiagnostics(
    buckets: [
      GitHubRateBucketDiagnostics(
        resource: "graphql",
        remaining: 4_612,
        limit: 5_000,
        used: 388,
        resetAt: "2026-05-25T13:00:00Z"
      ),
      GitHubRateBucketDiagnostics(
        resource: "core",
        remaining: 4_920,
        limit: 5_000,
        used: 80,
        resetAt: "2026-05-25T13:00:00Z"
      ),
    ],
    cooling: [],
    lastHourNetworkRequests: 42,
    lastHourGraphqlPoints: 388,
    cacheHits: 118,
    cacheStaleHits: 7,
    cacheDeferredHits: 2,
    deferredBudget: 2,
    topOperations: [
      GitHubOperationSpendDiagnostics(
        operation: "reviews.query",
        networkRequests: 18,
        graphqlPoints: 210
      ),
      GitHubOperationSpendDiagnostics(
        operation: "reviews.timeline",
        networkRequests: 9,
        graphqlPoints: 96
      ),
    ]
  )
}
