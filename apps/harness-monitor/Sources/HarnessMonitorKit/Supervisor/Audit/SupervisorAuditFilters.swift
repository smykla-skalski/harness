import Foundation

/// Query filters for `SupervisorAuditRepository.fetchEvents`. An empty filter matches every row.
///
/// `searchText` is applied in-memory against fetched rows (the persisted `payloadJSON` plus the
/// `ruleID`); all other fields translate into a `#Predicate` against SwiftData.
public struct SupervisorAuditFilters: Sendable, Equatable {
  public var ruleIDs: Set<String>
  public var kinds: Set<SupervisorEvent.Kind>
  public var severities: Set<SupervisorEvent.Severity>
  public var dateRange: ClosedRange<Date>?
  public var searchText: String
  public var decisionID: UUID?

  public init(
    ruleIDs: Set<String> = [],
    kinds: Set<SupervisorEvent.Kind> = [],
    severities: Set<SupervisorEvent.Severity> = [],
    dateRange: ClosedRange<Date>? = nil,
    searchText: String = "",
    decisionID: UUID? = nil
  ) {
    self.ruleIDs = ruleIDs
    self.kinds = kinds
    self.severities = severities
    self.dateRange = dateRange
    self.searchText = searchText
    self.decisionID = decisionID
  }

  /// `true` when no filter is set. `searchText` counts only when it has non-whitespace content.
  public var isEmpty: Bool {
    ruleIDs.isEmpty
      && kinds.isEmpty
      && severities.isEmpty
      && dateRange == nil
      && decisionID == nil
      && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

/// Stable keyset-pagination anchor. Pairs the row's timestamp with its identifier so a tie on
/// `createdAt` still produces a strict ordering when paging in `createdAt` desc, `id` desc order.
public struct SupervisorAuditCursor: Sendable, Equatable {
  public var createdAt: Date
  public var id: UUID

  public init(createdAt: Date, id: UUID) {
    self.createdAt = createdAt
    self.id = id
  }
}
