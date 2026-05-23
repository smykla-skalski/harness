import Foundation
import HarnessMonitorKit

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
  @ObservationIgnored public let userDefaults: UserDefaults

  /// Storage key for the round-trip blob.
  @ObservationIgnored public let storageKey: String

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

  public func setKind(_ kind: SupervisorEvent.Kind, selected: Bool) {
    if selected {
      filters.kinds.insert(kind)
    } else {
      filters.kinds.remove(kind)
    }
  }

  public func toggleKind(_ kind: SupervisorEvent.Kind) {
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

  public func setDateRange(_ range: ClosedRange<Date>?) {
    filters.dateRange = range
  }

  public func setSearchText(_ text: String) {
    filters.searchText = text
  }

  public func setDecisionID(_ id: UUID?) {
    filters.decisionID = id
  }

  public func clear() {
    guard !filters.isEmpty else { return }
    filters = .init()
  }
}
