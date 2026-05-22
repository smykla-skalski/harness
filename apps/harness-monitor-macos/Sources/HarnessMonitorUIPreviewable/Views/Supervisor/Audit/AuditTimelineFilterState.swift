import Foundation
import HarnessMonitorKit

// MARK: - Stubs (TEMPORARY — Unit 1 supersedes; coordinator removes during cherry-pick)
//
// Unit 1 of the audit-timeline batch owns the real `SupervisorAuditFilters`
// value type. Until that work lands we mirror the documented shape here so the
// filter chrome can compile and tests can exercise the round-trip. The
// coordinator strips this block (and the `import HarnessMonitorKit` keeps the
// `DecisionSeverity` import we already needed) during cherry-pick.

#if !AUDIT_FILTERS_SUPPLIED_BY_UNIT_1
/// Inclusive date range for audit filtering.
public struct SupervisorAuditDateRange: Equatable, Hashable, Sendable, Codable {
  public var start: Date
  public var end: Date

  public init(start: Date, end: Date) {
    self.start = start
    self.end = end
  }
}

/// Stub value type matching the prompt's filter shape.
///
/// Kinds are strings to match the persisted `SupervisorEvent.kind: String`.
/// Severities reuse the real `DecisionSeverity` enum to match every other
/// audit-pane surface in the app.
public struct SupervisorAuditFilters: Equatable, Hashable, Sendable {
  public var ruleIDs: Set<String>
  public var kinds: Set<String>
  public var severities: Set<DecisionSeverity>
  public var dateRange: SupervisorAuditDateRange?
  public var searchText: String
  public var decisionID: String?

  public init(
    ruleIDs: Set<String> = [],
    kinds: Set<String> = [],
    severities: Set<DecisionSeverity> = [],
    dateRange: SupervisorAuditDateRange? = nil,
    searchText: String = "",
    decisionID: String? = nil
  ) {
    self.ruleIDs = ruleIDs
    self.kinds = kinds
    self.severities = severities
    self.dateRange = dateRange
    self.searchText = searchText
    self.decisionID = decisionID
  }

  public var trimmedSearchText: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var isEmpty: Bool {
    ruleIDs.isEmpty
      && kinds.isEmpty
      && severities.isEmpty
      && dateRange == nil
      && trimmedSearchText.isEmpty
      && decisionID == nil
  }
}
#endif

// MARK: - Filter state

/// Observable filter container for the Supervisor Audit Timeline.
///
/// Mirrors the role of `SessionTimelineFilterState` for the PR timeline but
/// the audit timeline only needs a single live container, not a per-window
/// registry, so we wrap the value with `@Observable` rather than offering a
/// `Binding`-driven struct.
@Observable
public final class AuditTimelineFilterState: @unchecked Sendable {
  public var filters: SupervisorAuditFilters {
    didSet {
      guard filters != oldValue else { return }
      persist()
    }
  }

  /// UserDefaults instance to round-trip through. Tests inject a transient one.
  @ObservationIgnored
  public let userDefaults: UserDefaults

  /// Storage key for the round-trip blob.
  @ObservationIgnored
  public let storageKey: String

  public init(
    filters: SupervisorAuditFilters = .init(),
    userDefaults: UserDefaults = .standard,
    storageKey: String = AuditTimelineFilterDefaults.filtersKey
  ) {
    self.userDefaults = userDefaults
    self.storageKey = storageKey
    self.filters = filters
    if filters == SupervisorAuditFilters() {
      hydrate()
    }
  }

  /// `true` when any axis is engaged. Mirrors `SupervisorAuditFilters.isEmpty == false`.
  public var isAnyActive: Bool {
    !filters.isEmpty
  }

  // MARK: - Convenience setters

  public func setRuleID(_ ruleID: String, selected: Bool) {
    if selected {
      filters.ruleIDs.insert(ruleID)
    } else {
      filters.ruleIDs.remove(ruleID)
    }
  }

  public func toggleRuleID(_ ruleID: String) {
    setRuleID(ruleID, selected: !filters.ruleIDs.contains(ruleID))
  }

  public func clearRuleIDs() {
    guard !filters.ruleIDs.isEmpty else { return }
    filters.ruleIDs = []
  }

  public func setKind(_ kind: String, selected: Bool) {
    if selected {
      filters.kinds.insert(kind)
    } else {
      filters.kinds.remove(kind)
    }
  }

  public func toggleKind(_ kind: String) {
    setKind(kind, selected: !filters.kinds.contains(kind))
  }

  public func clearKinds() {
    guard !filters.kinds.isEmpty else { return }
    filters.kinds = []
  }

  public func setSeverity(_ severity: DecisionSeverity, selected: Bool) {
    if selected {
      filters.severities.insert(severity)
    } else {
      filters.severities.remove(severity)
    }
  }

  public func toggleSeverity(_ severity: DecisionSeverity) {
    setSeverity(severity, selected: !filters.severities.contains(severity))
  }

  public func clearSeverities() {
    guard !filters.severities.isEmpty else { return }
    filters.severities = []
  }

  public func setDateRange(_ range: SupervisorAuditDateRange?) {
    filters.dateRange = range
  }

  public func setSearchText(_ text: String) {
    filters.searchText = text
  }

  public func setDecisionID(_ id: String?) {
    filters.decisionID = id
  }

  public func clear() {
    guard !filters.isEmpty else { return }
    filters = .init()
  }
}
