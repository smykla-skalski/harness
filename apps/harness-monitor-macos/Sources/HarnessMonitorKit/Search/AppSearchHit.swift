import Foundation

/// A single search match.
///
/// Pure data with no UI-layer closures so it stays `Sendable` and can cross
/// the ``AppSearchIndex`` actor boundary. Routing is wired at the call site
/// by the suggestions view, which binds `domain` + `id` to the active state
/// cache's selection helpers.
public struct AppSearchHit: Identifiable, Hashable, Sendable {
  public let domain: AppSearchDomain
  public let id: String
  public let title: String
  public let subtitle: String?
  /// Right-edge metadata aligned with the title's first line. Agents
  /// surface the runtime here (gemini, copilot, ...); other domains
  /// leave it nil.
  public let trailing: String?
  public let systemImage: String
  /// Lower is better. Used only for stable ordering inside a section; the
  /// UI never reads it directly.
  public let score: Int

  public init(
    domain: AppSearchDomain,
    id: String,
    title: String,
    subtitle: String?,
    trailing: String? = nil,
    systemImage: String,
    score: Int
  ) {
    self.domain = domain
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.trailing = trailing
    self.systemImage = systemImage
    self.score = score
  }
}
