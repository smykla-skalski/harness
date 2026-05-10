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
}

/// Cross-domain text-search index for the session window.
///
/// The index is an `actor` because re-tokenising tens of thousands of
/// records on every keystroke would saturate the `@MainActor`. Re-index
/// happens incrementally on a `(count, lastID)` signature change at the
/// view layer; `search(...)` is a pure read against precomputed
/// lowercased corpora so it never allocates for each keystroke.
public actor AppSearchIndex {
  /// Cap on hits returned for the active route's primary domain.
  /// More room for the section the user is most likely scanning.
  public static let defaultPrimaryK = 15

  /// Cap on hits returned for non-primary fallback domains. Smaller
  /// so the popover surfaces matches across more domains at once
  /// without scrolling.
  public static let defaultFallbackK = 5

  /// Backing store for one indexed record. Lowercased corpora are
  /// precomputed so search avoids per-keystroke allocation.
  private struct Record: Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let trailing: String?
    let lowercasedTitle: String
    let lowercasedCorpus: String
  }

  private struct ScoredRecord {
    let score: Int
    let record: Record
  }

  private var agents: [Record] = []
  private var decisions: [Record] = []
  private var tasks: [Record] = []
  private var events: [Record] = []

  public init() {}

  // MARK: Reindex

  public func reindex(agents snapshot: [AgentRegistration]) {
    agents = snapshot.map { agent in
      let parts = [
        agent.name,
        agent.persona?.name,
        agent.persona?.description,
        agent.agentId,
        agent.role.rawValue,
        agent.runtime,
      ].compactMap { $0 }
      return makeRecord(
        id: agent.agentId,
        title: agent.name,
        subtitle: agent.persona?.name,
        trailing: agent.runtime,
        corpusParts: parts
      )
    }
  }

  public func reindex(decisions snapshot: [DecisionSearchProjection]) {
    decisions = snapshot.map { decision in
      let parts = [
        decision.summary,
        decision.ruleID,
        decision.agentID ?? "",
        decision.taskID ?? "",
      ]
      return makeRecord(
        id: decision.id,
        title: decision.summary,
        subtitle: decision.ruleID.isEmpty ? nil : decision.ruleID,
        trailing: nil,
        corpusParts: parts
      )
    }
  }

  public func reindex(tasks snapshot: [WorkItem]) {
    tasks = snapshot.map { task in
      let parts = [
        task.title,
        task.context ?? "",
        task.suggestedFix ?? "",
        task.blockedReason ?? "",
        task.taskId,
      ]
      return makeRecord(
        id: task.taskId,
        title: task.title,
        subtitle: task.assignedTo,
        trailing: nil,
        corpusParts: parts
      )
    }
  }

  public func reindex(events snapshot: [TimelineEntry]) {
    events = snapshot.map { entry in
      let parts = [
        entry.summary,
        entry.kind,
        entry.agentId ?? "",
        entry.taskId ?? "",
      ]
      return makeRecord(
        id: entry.entryId,
        title: entry.summary.isEmpty ? entry.kind : entry.summary,
        subtitle: entry.kind,
        trailing: nil,
        corpusParts: parts
      )
    }
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
    let needle = trimmed.lowercased()
    let domainOrder = orderedDomains(primary: primary)
    var sections: [AppSearchSection] = []
    sections.reserveCapacity(domainOrder.count)
    for domain in domainOrder {
      let perDomainK = (domain == primary) ? primaryK : fallbackK
      let section = searchDomain(domain, needle: needle, perDomainK: perDomainK)
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
    corpusParts: [String]
  ) -> Record {
    let nonEmptyParts = corpusParts.filter { !$0.isEmpty }
    let corpus = nonEmptyParts.joined(separator: " ").lowercased()
    return Record(
      id: id,
      title: title,
      subtitle: subtitle,
      trailing: trailing,
      lowercasedTitle: title.lowercased(),
      lowercasedCorpus: corpus
    )
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

  private func corpus(for domain: AppSearchDomain) -> [Record] {
    switch domain {
    case .agents:
      agents
    case .decisions:
      decisions
    case .tasks:
      tasks
    case .timeline:
      events
    }
  }

  private func searchDomain(
    _ domain: AppSearchDomain,
    needle: String,
    perDomainK: Int
  ) -> AppSearchSection {
    let records = corpus(for: domain)
    let limit = max(0, perDomainK)
    var scored: [ScoredRecord] = []
    scored.reserveCapacity(min(limit, records.count))
    var matchCount = 0
    for record in records {
      guard let score = score(record: record, needle: needle) else {
        continue
      }
      matchCount += 1
      appendTopMatch(
        ScoredRecord(score: score, record: record),
        to: &scored,
        limit: limit
      )
    }
    scored.sort(by: sortsBefore)
    let truncated = matchCount > limit
    let hits = scored.map { entry in
      AppSearchHit(
        domain: domain,
        id: entry.record.id,
        title: entry.record.title,
        subtitle: entry.record.subtitle,
        trailing: entry.record.trailing,
        systemImage: domain.systemImage,
        score: entry.score
      )
    }
    return AppSearchSection(domain: domain, hits: hits, truncated: truncated)
  }

  private func appendTopMatch(
    _ candidate: ScoredRecord,
    to scored: inout [ScoredRecord],
    limit: Int
  ) {
    guard limit > 0 else { return }
    guard scored.count >= limit else {
      scored.append(candidate)
      return
    }
    guard let worstIndex = scored.indices.max(by: { sortsBefore(scored[$0], scored[$1]) }) else {
      return
    }
    if sortsBefore(candidate, scored[worstIndex]) {
      scored[worstIndex] = candidate
    }
  }

  private func sortsBefore(_ lhs: ScoredRecord, _ rhs: ScoredRecord) -> Bool {
    if lhs.score != rhs.score {
      return lhs.score < rhs.score
    }
    return lhs.record.title.localizedCompare(rhs.record.title) == .orderedAscending
  }

  /// Score: lower is better. Title matches outrank corpus matches; within a
  /// match class, earlier substring positions outrank later ones. Returns
  /// `nil` when neither title nor corpus contains the needle.
  private func score(record: Record, needle: String) -> Int? {
    if let titleRange = record.lowercasedTitle.range(of: needle) {
      let position = record.lowercasedTitle.distance(
        from: record.lowercasedTitle.startIndex,
        to: titleRange.lowerBound
      )
      return -1_000 + position
    }
    if let corpusRange = record.lowercasedCorpus.range(of: needle) {
      let position = record.lowercasedCorpus.distance(
        from: record.lowercasedCorpus.startIndex,
        to: corpusRange.lowerBound
      )
      return position
    }
    return nil
  }
}
