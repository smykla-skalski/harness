import Foundation

/// `Sendable` projection of a SwiftData ``Decision`` row.
///
/// `Decision` is an `@Model` class and therefore not `Sendable`. Callers
/// build this struct on the `@MainActor` before handing the snapshot to
/// the search actor, so the `@Model` reads stay isolated and the actor
/// boundary only sees value-typed copies.
public struct DecisionSearchProjection: Hashable, Sendable {
  public let id: String
  public let summary: String
  public let ruleID: String
  public let agentID: String?
  public let taskID: String?

  public init(
    id: String,
    summary: String,
    ruleID: String,
    agentID: String?,
    taskID: String?
  ) {
    self.id = id
    self.summary = summary
    self.ruleID = ruleID
    self.agentID = agentID
    self.taskID = taskID
  }

  public init(decision: Decision) {
    self.init(
      id: decision.id,
      summary: decision.summary,
      ruleID: decision.ruleID,
      agentID: decision.agentID,
      taskID: decision.taskID
    )
  }
}

/// Cross-domain text-search index for the session window.
///
/// The index is an `actor` because re-tokenising tens of thousands of
/// records on every keystroke would saturate the `@MainActor`. Re-index
/// happens incrementally on a `(count, lastID)` signature change at the
/// view layer; `search(...)` is a pure read against precomputed searchers.
public actor AppSearchIndex {
  /// Cap on hits returned for the active route's primary domain.
  /// Keep the toolbar search popover compact; large suggestion lists rebuild
  /// the AppKit-backed search field and dominate SwiftUI update cost.
  public static let defaultPrimaryK = 3

  /// Cap on hits returned for non-primary fallback domains. Smaller
  /// so the popover surfaces matches across more domains at once
  /// without scrolling.
  public static let defaultFallbackK = 1

  private struct Record: Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let trailing: String?
    let searchBody: String
  }

  private static let fields: [FuzzySearchField<Record>] = [
    .single("title", weight: 0.75, highlightField: .title, prefixRank: 0) { $0.title },
    .single("subtitle", weight: 0.45, highlightField: .subtitle, prefixRank: 1) {
      $0.subtitle
    },
    .single("trailing", weight: 0.2, highlightField: .trailing, prefixRank: 2) {
      $0.trailing
    },
    .single("searchBody", weight: 0.3) {
      $0.searchBody.isEmpty ? nil : $0.searchBody
    },
  ]

  private var agentIndex: FuzzySearchIndex<Record>
  private var decisionIndex: FuzzySearchIndex<Record>
  private var taskIndex: FuzzySearchIndex<Record>
  private var eventIndex: FuzzySearchIndex<Record>

  public init() {
    agentIndex = Self.makeIndex(records: [])
    decisionIndex = Self.makeIndex(records: [])
    taskIndex = Self.makeIndex(records: [])
    eventIndex = Self.makeIndex(records: [])
  }

  // MARK: Reindex

  public func reindex(agents snapshot: [AgentRegistration]) {
    let records = snapshot.map { agent in
      makeRecord(
        id: agent.agentId,
        title: agent.name,
        subtitle: agent.persona?.name,
        trailing: agent.runtime,
        searchBodyParts: [
          agent.persona?.description,
          agent.agentId,
          agent.role.rawValue,
        ]
      )
    }
    agentIndex = Self.makeIndex(records: records)
  }

  public func reindex(decisions snapshot: [DecisionSearchProjection]) {
    let records = snapshot.map { decision in
      makeRecord(
        id: decision.id,
        title: decision.summary,
        subtitle: decision.ruleID.isEmpty ? nil : decision.ruleID,
        trailing: nil,
        searchBodyParts: [
          decision.agentID,
          decision.taskID,
        ]
      )
    }
    decisionIndex = Self.makeIndex(records: records)
  }

  public func reindex(tasks snapshot: [WorkItem]) {
    let records = snapshot.map { task in
      makeRecord(
        id: task.taskId,
        title: task.title,
        subtitle: task.assignedTo,
        trailing: nil,
        searchBodyParts: [
          task.context,
          task.suggestedFix,
          task.blockedReason,
          task.taskId,
        ]
      )
    }
    taskIndex = Self.makeIndex(records: records)
  }

  public func reindex(events snapshot: [TimelineEntry]) {
    let records = snapshot.map { entry in
      makeRecord(
        id: entry.entryId,
        title: entry.summary.isEmpty ? entry.kind : entry.summary,
        subtitle: entry.kind,
        trailing: nil,
        searchBodyParts: [
          entry.agentId,
          entry.taskId,
        ]
      )
    }
    eventIndex = Self.makeIndex(records: records)
  }

  // MARK: Search

  public func search(
    query: String,
    primary: AppSearchDomain?,
    primaryK: Int = AppSearchIndex.defaultPrimaryK,
    fallbackK: Int = AppSearchIndex.defaultFallbackK
  ) -> AppSearchResults {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return AppSearchResults(query: trimmed, primaryDomain: primary, sections: [])
    }
    let domainOrder = orderedDomains(primary: primary)
    var sections: [AppSearchSection] = []
    sections.reserveCapacity(domainOrder.count)
    for domain in domainOrder {
      let perDomainK = (domain == primary) ? primaryK : fallbackK
      let section = searchDomain(domain, needle: trimmed, perDomainK: perDomainK)
      guard !section.hits.isEmpty else {
        continue
      }
      sections.append(section)
    }
    return AppSearchResults(
      query: trimmed,
      primaryDomain: primary,
      sections: sections
    )
  }

  // MARK: Helpers

  private func makeRecord(
    id: String,
    title: String,
    subtitle: String?,
    trailing: String?,
    searchBodyParts: [String?]
  ) -> Record {
    Record(
      id: id,
      title: title,
      subtitle: subtitle,
      trailing: trailing,
      searchBody:
        searchBodyParts
        .compactMap { value in
          guard let value else { return nil }
          return value.isEmpty ? nil : value
        }
        .joined(separator: " ")
    )
  }

  private static func makeIndex(
    records: [Record]
  ) -> FuzzySearchIndex<Record> {
    do {
      return try FuzzySearchIndex(
        items: records,
        fields: fields
      )
    } catch {
      preconditionFailure("Failed to build AppSearchIndex: \(error)")
    }
  }

  /// Ranked fallback order for non-primary domains.
  ///
  /// Tasks lead, then Agents, then Timeline, with Decisions trailing.
  /// The active route's domain (the `primary`) always anchors the head
  /// of the returned list; remaining domains follow this fallback
  /// order.
  private static let fallbackDomainOrder: [AppSearchDomain] = [
    .tasks,
    .agents,
    .timeline,
    .decisions,
  ]

  private func orderedDomains(primary: AppSearchDomain?) -> [AppSearchDomain] {
    guard let primary else {
      return Self.fallbackDomainOrder
    }
    return [primary] + Self.fallbackDomainOrder.filter { $0 != primary }
  }

  private func index(for domain: AppSearchDomain) -> FuzzySearchIndex<Record> {
    switch domain {
    case .agents:
      agentIndex
    case .decisions:
      decisionIndex
    case .tasks:
      taskIndex
    case .timeline:
      eventIndex
    }
  }

  private func searchDomain(
    _ domain: AppSearchDomain,
    needle: String,
    perDomainK: Int
  ) -> AppSearchSection {
    let limit = max(0, perDomainK)
    guard limit > 0 else {
      return AppSearchSection(domain: domain, hits: [], truncated: false)
    }

    let matches = index(for: domain).topResults(
      needle,
      limit: limit,
      sortedBy: candidateSortsBefore
    )
    let hits = matches.results.map { entry in
      AppSearchHit(
        domain: domain,
        id: entry.item.id,
        title: entry.item.title,
        subtitle: entry.item.subtitle,
        trailing: entry.item.trailing,
        systemImage: domain.systemImage,
        highlights: entry.highlights,
        score: entry.score
      )
    }
    return AppSearchSection(domain: domain, hits: hits, truncated: matches.isTruncated)
  }

  private func candidateSortsBefore(
    _ lhs: FuzzySearchCandidate<Record>,
    _ rhs: FuzzySearchCandidate<Record>
  ) -> Bool {
    if lhs.score != rhs.score {
      return lhs.score < rhs.score
    }
    return lhs.item.title.localizedCompare(rhs.item.title) == .orderedAscending
  }
}
