import Foundation
import SwiftData

struct SupervisorDecisionSeedPayload: Decodable {
  let decisions: [DecisionLine]

  struct DecisionLine: Decodable {
    let id: String
    let severity: String
    let ruleID: String
    let sessionID: String?
    let agentID: String?
    let taskID: String?
    let summary: String
    let contextJSON: String?
    let suggestedActionsJSON: String?
  }
}

actor SwiftDataSupervisorAuditWriter: SupervisorAuditWriter {
  private let container: ModelContainer

  init(container: ModelContainer) {
    self.container = container
  }

  func append(_ record: SupervisorAuditRecord) async throws {
    do {
      let context = ModelContext(container)
      context.autosaveEnabled = false
      context.insert(
        SupervisorEvent(
          id: record.id,
          tickID: record.tickID,
          kind: record.kind,
          ruleID: record.ruleID,
          severity: record.severity,
          payloadJSON: record.payloadJSON,
          createdAt: record.createdAt
        )
      )
      try context.save()
    } catch {
      HarnessMonitorLogger.supervisorWarning(
        "supervisor.audit_append_failed error=\(String(describing: error))"
      )
      throw error
    }
  }
}

struct NoOpSupervisorAuditWriter: SupervisorAuditWriter {
  func append(_ record: SupervisorAuditRecord) async throws {
    _ = record
  }
}

public actor SupervisorAuditRepository {
  private let container: ModelContainer

  public init(container: ModelContainer) {
    self.container = container
  }

  /// Convenience wrapper that delegates to ``fetchEvents(filters:limit:before:)`` with no filters
  /// and no pagination cursor.
  public func fetchEvents(limit: Int = 128) throws -> [SupervisorEventSnapshot] {
    try fetchEvents(filters: SupervisorAuditFilters(), limit: limit, before: nil)
  }

  /// Fetch the next page of audit events matching `filters`. Returns up to `limit` rows ordered
  /// `createdAt` desc then `id` desc. `before` is a keyset anchor — pass the last row of the prior
  /// page to advance the cursor. `searchText` and `decisionID` are applied in-memory on the slice
  /// returned from SwiftData.
  public func fetchEvents(
    filters: SupervisorAuditFilters,
    limit: Int,
    before cursor: SupervisorAuditCursor?
  ) throws -> [SupervisorEventSnapshot] {
    let context = ModelContext(container)
    let predicate = Self.makePredicate(filters: filters, cursor: cursor)
    var descriptor = FetchDescriptor<SupervisorEvent>(
      predicate: predicate,
      sortBy: [
        SortDescriptor(\.createdAt, order: .reverse),
        SortDescriptor(\.id, order: .reverse),
      ]
    )
    descriptor.fetchLimit = Self.fetchLimit(for: filters, requested: limit)
    let rows = try context.fetch(descriptor)
    let filtered = Self.applyInMemoryFilters(rows, filters: filters)
    let trimmed = Array(filtered.prefix(limit))
    return trimmed.map(SupervisorEventSnapshot.init(event:))
  }

  public func waitForIdle() async {}

  // MARK: - Predicate construction

  /// Builds a predicate covering all fields SwiftData can index directly: `kind`, `createdAt`,
  /// and the cursor anchor. `severityRaw`, `ruleID`, the `decisionID` payload lookup, and
  /// `searchText` are sparse or content-typed, so they run in-memory on the fetched slice.
  ///
  /// `cursorActive` and `rangeActive` are precomputed booleans so the predicate body avoids
  /// optionality and stays in the subset SwiftData reliably translates to its backing store.
  private static func makePredicate(
    filters: SupervisorAuditFilters,
    cursor: SupervisorAuditCursor?
  ) -> Predicate<SupervisorEvent> {
    let kindValues = filters.kinds.map(\.rawValue)
    let rangeActive = filters.dateRange != nil
    let rangeStart = filters.dateRange?.lowerBound ?? Date.distantPast
    let rangeEnd = filters.dateRange?.upperBound ?? Date.distantFuture
    let cursorActive = cursor != nil
    let cursorDate = cursor?.createdAt ?? Date.distantFuture
    let cursorID = cursor?.id.uuidString ?? ""

    return #Predicate<SupervisorEvent> { event in
      (kindValues.isEmpty || kindValues.contains(event.kind))
        && (!rangeActive || (event.createdAt >= rangeStart && event.createdAt <= rangeEnd))
        && (!cursorActive
          || event.createdAt < cursorDate
          || (event.createdAt == cursorDate && event.id < cursorID))
    }
  }

  /// Over-fetch when in-memory filters (severity, rule, decision-id, search) will trim rows after
  /// SwiftData returns. The cap stays in line with the existing 128-default to keep work bounded.
  private static func fetchLimit(for filters: SupervisorAuditFilters, requested: Int) -> Int {
    let needsInMemory = !filters.severities.isEmpty
      || !filters.ruleIDs.isEmpty
      || filters.decisionID != nil
      || !filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let overFetchCap = 512
    let target = max(requested, 1)
    return needsInMemory ? min(overFetchCap, target * 4) : target
  }

  private static func applyInMemoryFilters(
    _ rows: [SupervisorEvent],
    filters: SupervisorAuditFilters
  ) -> [SupervisorEvent] {
    let needle = filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let decisionIDString = filters.decisionID?.uuidString.lowercased()
    let severityValues = Set(filters.severities.map(\.rawValue))
    return rows.filter { event in
      if !filters.ruleIDs.isEmpty {
        guard let ruleID = event.ruleID, filters.ruleIDs.contains(ruleID) else {
          return false
        }
      }
      if !severityValues.isEmpty {
        guard let raw = event.severityRaw, severityValues.contains(raw) else {
          return false
        }
      }
      if let decisionIDString,
        !event.payloadJSON.lowercased().contains(decisionIDString) {
        return false
      }
      if !needle.isEmpty {
        let haystack = (event.payloadJSON + " " + (event.ruleID ?? "")).lowercased()
        guard haystack.contains(needle) else {
          return false
        }
      }
      return true
    }
  }
}

extension HarnessMonitorStore {
  func seedSupervisorDecisionsIfNeeded(_ decisionStore: DecisionStore) async throws {
    let environmentKey = "HARNESS_MONITOR_SUPERVISOR_SEED_DECISIONS"
    guard
      let rawValue = ProcessInfo.processInfo.environment[environmentKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !rawValue.isEmpty
    else {
      return
    }

    let payload = try JSONDecoder().decode(
      SupervisorDecisionSeedPayload.self,
      from: Data(rawValue.utf8)
    )
    for seededDecision in payload.decisions {
      guard let severity = DecisionSeverity(rawValue: seededDecision.severity) else {
        continue
      }
      try await decisionStore.insert(
        DecisionDraft(
          id: seededDecision.id,
          severity: severity,
          ruleID: seededDecision.ruleID,
          sessionID: seededDecision.sessionID,
          agentID: seededDecision.agentID,
          taskID: seededDecision.taskID,
          summary: seededDecision.summary,
          contextJSON: seededDecision.contextJSON ?? "{}",
          suggestedActionsJSON: seededDecision.suggestedActionsJSON ?? "[]"
        )
      )
    }
  }

  static func loadPolicyOverrides(
    from modelContext: ModelContext?
  ) -> [PolicyConfigOverride] {
    guard let modelContext else {
      return []
    }

    do {
      let descriptor = FetchDescriptor<PolicyConfigRow>(
        sortBy: [SortDescriptor(\.ruleID)]
      )
      return try modelContext.fetch(descriptor).map { row in
        PolicyConfigOverride(
          ruleID: row.ruleID,
          enabled: row.enabled,
          defaultBehavior: RuleDefaultBehavior(rawValue: row.defaultBehaviorRaw) ?? .cautious,
          parameters: decodeParameters(from: row.parametersJSON)
        )
      }
    } catch {
      HarnessMonitorLogger.supervisorWarning(
        "supervisor.policy_config_load_failed error=\(String(describing: error))"
      )
      return []
    }
  }

  func loadPolicyOverrides() async -> [PolicyConfigOverride] {
    guard let supervisorPolicyConfigRepository else {
      return []
    }
    do {
      return try await supervisorPolicyConfigRepository.fetchOverrides()
    } catch {
      HarnessMonitorLogger.supervisorWarning(
        "supervisor.policy_config_load_failed error=\(String(describing: error))"
      )
      return []
    }
  }

  public static func loadSupervisorAuditEvents(
    from modelContext: ModelContext?,
    limit: Int = 128
  ) -> [SupervisorEvent] {
    guard let modelContext else {
      return []
    }

    do {
      var descriptor = FetchDescriptor<SupervisorEvent>(
        sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
      )
      descriptor.fetchLimit = limit
      return try modelContext.fetch(descriptor)
    } catch {
      HarnessMonitorLogger.supervisorWarning(
        "supervisor.audit_event_load_failed error=\(String(describing: error))"
      )
      return []
    }
  }

  public func loadSupervisorAuditEventSnapshots(limit: Int = 128) async -> [SupervisorEventSnapshot]
  {
    guard let supervisorAuditRepository else {
      return []
    }
    do {
      return try await supervisorAuditRepository.fetchEvents(limit: limit)
    } catch {
      HarnessMonitorLogger.supervisorWarning(
        "supervisor.audit_event_load_failed error=\(String(describing: error))"
      )
      return []
    }
  }

  static func decodeParameters(from json: String) -> [String: String] {
    guard
      let data = json.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return [:]
    }

    var parameters: [String: String] = [:]
    for (key, value) in object {
      switch value {
      case let string as String:
        parameters[key] = string
      case let number as NSNumber:
        parameters[key] = number.stringValue
      default:
        continue
      }
    }
    return parameters
  }
}
