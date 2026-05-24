import Foundation

/// A grouped slice of ``AppSearchHit`` values for a single domain.
///
/// The section is `Identifiable` by its domain so SwiftUI's `ForEach` can
/// diff stably even as section ordering shifts (primary section moves to
/// the top when the active route changes).
public struct AppSearchSection: Identifiable, Hashable, Sendable {
  public let domain: AppSearchDomain
  public let hits: [AppSearchHit]
  /// `true` when the index found more matches than `perDomainK` and
  /// truncated the list. The UI uses this to render a "Show more" hint
  /// without having to ask the index for a count.
  public let truncated: Bool

  public var id: AppSearchDomain { domain }

  public init(domain: AppSearchDomain, hits: [AppSearchHit], truncated: Bool) {
    self.domain = domain
    self.hits = hits
    self.truncated = truncated
  }
}
