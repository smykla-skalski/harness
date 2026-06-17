import Foundation

// Maps the small self-contained hand models of the reviews types.rs cluster to
// the generated wire types in Models/Generated/ReviewsTypesWireTypes.generated
// .swift. These leaves (repository catalog, body, cache-clear) carry no nested
// ReviewItem graph, so they reroute independently of the larger
// queryReviews/ReviewItem mapping. The wire types own the daemon snake_case
// shape with explicit CodingKeys, so the decode runs through them on the plain
// PolicyWireCoding decoder instead of riding convertFromSnakeCase - notably the
// body pull_request_id / pr_updated_at and the cache cleared_entries, which the
// hand models decoded via convert.

extension ReviewsRepositoryCatalogResponse {
  init(wire: ReviewsRepositoryCatalogResponseWire) {
    self.init(organization: wire.organization, repositories: wire.repositories)
  }
}

extension ReviewsRepositoryCatalogRequestWire {
  init(_ model: ReviewsRepositoryCatalogRequest) {
    self.init(organization: model.organization)
  }
}

extension ReviewsBodyResponse {
  init(wire: ReviewsBodyResponseWire) {
    self.init(
      pullRequestID: wire.pullRequestId,
      body: wire.body,
      prUpdatedAt: wire.prUpdatedAt,
      fetchedAt: wire.fetchedAt,
      fromCache: wire.fromCache
    )
  }
}

extension ReviewsBodyRequestWire {
  init(_ model: ReviewsBodyRequest) {
    self.init(
      pullRequestId: model.pullRequestID,
      forceRefresh: model.forceRefresh,
      cacheMaxAgeSeconds: model.cacheMaxAgeSeconds
    )
  }
}

extension ReviewsCacheClearResponse {
  init(wire: ReviewsCacheClearResponseWire) {
    self.init(clearedEntries: Int(wire.clearedEntries))
  }
}
