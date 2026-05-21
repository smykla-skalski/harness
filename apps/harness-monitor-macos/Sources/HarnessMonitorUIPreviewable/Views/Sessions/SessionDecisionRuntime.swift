// swiftlint:disable file_length
import Foundation
import HarnessMonitorKit
import OSLog
import Observation

public enum SessionDecisionInspectorTab: String, CaseIterable, Codable, Hashable, Sendable {
  case context
  case history

  public var title: String {
    switch self {
    case .context: "Context"
    case .history: "History"
    }
  }
}

public struct SessionDecisionContextRow: Identifiable, Hashable, Sendable {
  public let id: String
  public let value: String
}

public struct SessionDecisionHistoryRow: Identifiable, Hashable, Sendable {
  public let id: String
  public let title: String
  public let value: String
}

struct SessionDecisionInspectorRowKey: Hashable, Sendable {
  let decisionID: String
  let sessionID: String?
  let contextHash: Int
  let createdAt: TimeInterval
  let statusRaw: String
  let snoozedUntil: TimeInterval?
  let resolutionHash: Int?
}

struct SessionDecisionInspectorRowInput: Equatable, Sendable {
  let key: SessionDecisionInspectorRowKey
  let decisionID: String
  let sessionID: String?
  let contextJSON: String
  let createdAt: Date
  let statusRaw: String
  let snoozedUntil: Date?
  let resolutionJSON: String?

  @MainActor
  init(decision: Decision) {
    decisionID = decision.id
    sessionID = decision.sessionID
    contextJSON = decision.contextJSON
    createdAt = decision.createdAt
    statusRaw = decision.statusRaw
    snoozedUntil = decision.snoozedUntil
    resolutionJSON = decision.resolutionJSON
    key = SessionDecisionInspectorRowKey(
      decisionID: decision.id,
      sessionID: decision.sessionID,
      contextHash: decision.contextJSON.hashValue,
      createdAt: decision.createdAt.timeIntervalSince1970,
      statusRaw: decision.statusRaw,
      snoozedUntil: decision.snoozedUntil?.timeIntervalSince1970,
      resolutionHash: decision.resolutionJSON?.hashValue
    )
  }
}

struct SessionDecisionInspectorRows: Equatable, Sendable {
  static let empty = Self(
    key: nil,
    decisionID: nil,
    contextRows: [],
    historyRows: [],
    isLoading: false
  )

  static func loading(
    key: SessionDecisionInspectorRowKey,
    decisionID: String
  ) -> Self {
    Self(
      key: key,
      decisionID: decisionID,
      contextRows: [],
      historyRows: [],
      isLoading: true
    )
  }

  static func loading(decisionID: String) -> Self {
    Self(
      key: nil,
      decisionID: decisionID,
      contextRows: [],
      historyRows: [],
      isLoading: true
    )
  }

  let key: SessionDecisionInspectorRowKey?
  let decisionID: String?
  let contextRows: [SessionDecisionContextRow]
  let historyRows: [SessionDecisionHistoryRow]
  let isLoading: Bool
}

public enum SessionInspectorVisibilityPolicy {
  public static let collapseThreshold: CGFloat = 1100

  public static func allowsInspector(width: CGFloat) -> Bool {
    width >= collapseThreshold
  }

  public static func shouldDeferVisibilityReconciliation(
    preferredVisible: Bool,
    hasInspectorContext: Bool,
    detailColumnWidth: CGFloat,
    focusMode: Bool
  ) -> Bool {
    preferredVisible
      && hasInspectorContext
      && !focusMode
      && detailColumnWidth == 0
  }

  public static func resolvedVisible(preferredVisible: Bool, canPresent: Bool) -> Bool {
    preferredVisible && canPresent
  }
}

@MainActor
@Observable
public final class SessionDecisionRuntime {
  public var inspectorTab: SessionDecisionInspectorTab = .context
  public private(set) var auditEvents: [SupervisorEventSnapshot] = []
  private(set) var auditEventPayloadPresentations: [String: DecisionAuditTrailPayloadPresentation] =
    [:]
  public private(set) var filteredDecisionIDs: [String] = []
  public private(set) var filteredDecisionItems: [DecisionPresentationSnapshot] = []
  public private(set) var filteredDecisionIDSet: Set<String> = []
  public private(set) var hasFilteredDecisions = false
  public private(set) var isFilteringDecisions = false
  private(set) var preparedInspectorRows = SessionDecisionInspectorRows.empty

  @ObservationIgnored private var inspectorRowCache:
    [SessionDecisionInspectorRowKey: SessionDecisionInspectorRows] = [:]
  @ObservationIgnored private var inspectorRowKeyOrder: [SessionDecisionInspectorRowKey] = []
  @ObservationIgnored nonisolated(unsafe) private var filterTask: Task<Void, Never>?
  @ObservationIgnored nonisolated(unsafe) private var inspectorRowTask: Task<Void, Never>?
  @ObservationIgnored private var latestFilterInput: SessionDecisionFilterInput?
  @ObservationIgnored private var latestInspectorRowKey: SessionDecisionInspectorRowKey?
  @ObservationIgnored private var inspectorRowGeneration: UInt64 = 0
  @ObservationIgnored private var auditReloadGeneration: UInt64 = 0

  private static let cacheLimit = 32
  private static let filterSignposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "perf/session-decision-filter"
  )
  private static let inspectorSignposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "perf/session-decision-inspector"
  )

  public init() {}

  // ARC may drop this `@MainActor` instance on a background thread (the
  // SwiftUI DisplayLink / dispatch worker), so `deinit` runs off-actor on
  // macOS 26 + Swift 6.2. `Task.cancel()` is itself thread-safe, but reading
  // `filterTask` from a `@MainActor`-isolated stored property in an off-actor
  // deinit traps libdispatch's queue assertion. Backing the storage with
  // `nonisolated(unsafe)` matches the project-wide pattern documented in the
  // assumeIsolated-in-deinit playbook.
  deinit {
    filterTask?.cancel()
    filterTask = nil
    inspectorRowTask?.cancel()
    inspectorRowTask = nil
  }

  public func updateFilteredDecisions(input: SessionDecisionFilterInput) {
    guard latestFilterInput != input else { return }
    latestFilterInput = input
    filterTask?.cancel()

    guard !input.items.isEmpty else {
      filterTask = nil
      filteredDecisionIDs = []
      filteredDecisionItems = []
      filteredDecisionIDSet = []
      hasFilteredDecisions = true
      isFilteringDecisions = false
      return
    }

    isFilteringDecisions = true
    filterTask = Task { @MainActor [weak self] in
      let signpostID = Self.filterSignposter.makeSignpostID()
      let interval = Self.filterSignposter.beginInterval(
        "session_decision_filter.apply",
        id: signpostID,
        "session=\(input.sessionID, privacy: .public) count=\(input.items.count, privacy: .public)"
      )
      let output = await sessionDecisionFilterWorker.filteredOutput(input: input)
      Self.filterSignposter.endInterval(
        "session_decision_filter.apply",
        interval,
        "matches=\(output.decisionIDs.count, privacy: .public)"
      )
      guard !Task.isCancelled else { return }
      guard let self, latestFilterInput == input else { return }
      filteredDecisionIDs = output.decisionIDs
      filteredDecisionItems = output.decisionItems
      filteredDecisionIDSet = Set(output.decisionIDs)
      hasFilteredDecisions = true
      isFilteringDecisions = false
    }
  }

  public func filteredDecisions(from decisions: [Decision]) -> [Decision] {
    guard hasFilteredDecisions else { return decisions }
    return decisions.filter { filteredDecisionIDSet.contains($0.id) }
  }

  public func waitForDecisionFilterIdle() async {
    await filterTask?.value
  }

  public func prepareInspectorRows(for decision: Decision) {
    let input = SessionDecisionInspectorRowInput(decision: decision)
    if latestInspectorRowKey == input.key,
      let cachedRows = inspectorRowCache[input.key],
      preparedInspectorRows == cachedRows
    {
      return
    }

    latestInspectorRowKey = input.key
    inspectorRowGeneration &+= 1
    let generation = inspectorRowGeneration

    if let cachedRows = inspectorRowCache[input.key] {
      inspectorRowTask?.cancel()
      preparedInspectorRows = cachedRows
      return
    }

    if preparedInspectorRows.key != input.key || !preparedInspectorRows.isLoading {
      preparedInspectorRows = .loading(key: input.key, decisionID: input.decisionID)
    }
    inspectorRowTask?.cancel()
    inspectorRowTask = Task { @MainActor [weak self, input, generation] in
      let signpostID = Self.inspectorSignposter.makeSignpostID()
      let computeInterval = Self.inspectorSignposter.beginInterval(
        "session_decision_inspector.compute",
        id: signpostID,
        "decision=\(input.decisionID, privacy: .public)"
      )
      let rows = await sessionDecisionInspectorRowWorker.compute(input: input)
      Self.inspectorSignposter.endInterval(
        "session_decision_inspector.compute",
        computeInterval,
        // swiftlint:disable:next line_length
        "contextRows=\(rows.contextRows.count, privacy: .public) historyRows=\(rows.historyRows.count, privacy: .public)"
      )
      guard !Task.isCancelled else { return }
      guard let self, inspectorRowGeneration == generation, latestInspectorRowKey == input.key
      else {
        return
      }
      let applyInterval = Self.inspectorSignposter.beginInterval(
        "session_decision_inspector.apply",
        id: signpostID,
        "decision=\(input.decisionID, privacy: .public)"
      )
      storeInspectorRows(rows, forKey: input.key)
      if preparedInspectorRows != rows {
        preparedInspectorRows = rows
      }
      Self.inspectorSignposter.endInterval(
        "session_decision_inspector.apply",
        applyInterval,
        "decision=\(input.decisionID, privacy: .public)"
      )
    }
  }

  public func waitForInspectorRowsIdle() async {
    await inspectorRowTask?.value
    await sessionDecisionInspectorRowWorker.waitForIdle()
  }

  public func reloadAuditEvents(
    from repository: SupervisorAuditRepository?,
    sessionID: String,
    decisionItems: [DecisionPresentationSnapshot]
  ) async {
    auditReloadGeneration &+= 1
    let generation = auditReloadGeneration
    guard let repository else {
      applyAuditReloadOutput(.empty, generation: generation)
      return
    }
    let input = SessionDecisionAuditInput(
      sessionID: sessionID,
      decisionItems: decisionItems
    )
    let loadedEvents = (try? await repository.fetchEvents(limit: 256)) ?? []
    let output = await sessionDecisionAuditWorker.scopedOutput(
      events: loadedEvents,
      input: input
    )
    applyAuditReloadOutput(output, generation: generation)
  }

  public func reloadAuditEvents(
    from repository: SupervisorAuditRepository?,
    sessionID: String,
    decisions: [Decision]
  ) async {
    await reloadAuditEvents(
      from: repository,
      sessionID: sessionID,
      decisionItems: decisions.map(DecisionPresentationSnapshot.init)
    )
  }

  private func applyAuditReloadOutput(
    _ output: SessionDecisionAuditOutput,
    generation: UInt64
  ) {
    guard auditReloadGeneration == generation else { return }
    guard
      auditEvents != output.events
        || auditEventPayloadPresentations != output.payloadPresentations
    else {
      return
    }
    auditEvents = output.events
    auditEventPayloadPresentations = output.payloadPresentations
  }

  public func contextRows(for decision: Decision) -> [SessionDecisionContextRow] {
    let key = SessionDecisionInspectorRowInput(decision: decision).key
    return inspectorRowCache[key]?.contextRows ?? []
  }

  public func historyRows(for decision: Decision) -> [SessionDecisionHistoryRow] {
    let key = SessionDecisionInspectorRowInput(decision: decision).key
    return inspectorRowCache[key]?.historyRows ?? []
  }

  func inspectorRows(for decisionID: String) -> SessionDecisionInspectorRows {
    guard preparedInspectorRows.decisionID == decisionID else {
      return .loading(decisionID: decisionID)
    }
    return preparedInspectorRows
  }

  public func allowsInspector(width: CGFloat) -> Bool {
    SessionInspectorVisibilityPolicy.allowsInspector(width: width)
  }

  private func storeInspectorRows(
    _ rows: SessionDecisionInspectorRows,
    forKey key: SessionDecisionInspectorRowKey
  ) {
    if inspectorRowCache[key] == nil {
      inspectorRowKeyOrder.append(key)
    }
    inspectorRowCache[key] = rows
    while inspectorRowKeyOrder.count > Self.cacheLimit {
      let evicted = inspectorRowKeyOrder.removeFirst()
      inspectorRowCache.removeValue(forKey: evicted)
    }
  }
}

private let sessionDecisionInspectorRowWorker = SessionDecisionInspectorRowWorker()
private let sessionDecisionAuditWorker = SessionDecisionAuditWorker()

actor SessionDecisionInspectorRowWorker {
  func compute(input: SessionDecisionInspectorRowInput) -> SessionDecisionInspectorRows {
    var contextRows: [SessionDecisionContextRow] = []
    if let sessionID = input.sessionID {
      contextRows.append(.init(id: "session", value: "Session: \(sessionID)"))
    }
    contextRows.append(contentsOf: Self.flattenedContextRows(from: input.contextJSON))

    var historyRows: [SessionDecisionHistoryRow] = [
      .init(id: "created", title: "Created", value: input.createdAt.formatted()),
      .init(id: "status", title: "Status", value: input.statusRaw),
    ]
    if let snoozedUntil = input.snoozedUntil {
      historyRows.append(
        .init(id: "snoozed", title: "Snoozed Until", value: snoozedUntil.formatted())
      )
    }
    if let resolutionJSON = input.resolutionJSON, !resolutionJSON.isEmpty {
      historyRows.append(.init(id: "resolution", title: "Resolution", value: resolutionJSON))
    }

    return SessionDecisionInspectorRows(
      key: input.key,
      decisionID: input.decisionID,
      contextRows: contextRows,
      historyRows: historyRows,
      isLoading: false
    )
  }

  func waitForIdle() async {}

  private static func flattenedContextRows(from json: String) -> [SessionDecisionContextRow] {
    guard let data = json.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return []
    }
    return object.keys.sorted()
      .filter { !isDetailOwnedContextKey($0) }
      .prefix(12)
      .map { key in
        SessionDecisionContextRow(id: "context.\(key)", value: "\(key): \(object[key] ?? "")")
      }
  }

  private static func isDetailOwnedContextKey(_ key: String) -> Bool {
    detailOwnedContextKeys.contains(normalizedContextKey(key))
  }

  private static func normalizedContextKey(_ key: String) -> String {
    key.lowercased().filter { $0.isLetter || $0.isNumber }
  }

  private static let detailOwnedContextKeys: Set<String> = [
    "agent",
    "agentid",
    "decision",
    "decisionid",
    "rule",
    "ruleid",
    "session",
    "sessionid",
    "severity",
    "severityraw",
    "status",
    "statusraw",
    "suggestedactions",
    "suggestedactionsjson",
    "summary",
    "task",
    "taskid",
  ]
}

private actor SessionDecisionAuditWorker {
  private let decoder = JSONDecoder()

  func scopedOutput(
    events: [SupervisorEventSnapshot],
    input: SessionDecisionAuditInput
  ) -> SessionDecisionAuditOutput {
    let scopedEvents = events.filter { event in
      SessionDecisionAuditPayloadScope(payloadJSON: event.payloadJSON)
        .matchesExplicitSessionScope(
          sessionID: input.sessionID,
          decisionIDs: input.decisionIDs,
          agentIDs: input.agentIDs,
          taskIDs: input.taskIDs
        )
    }
    return SessionDecisionAuditOutput(
      events: scopedEvents,
      payloadPresentations: Dictionary(
        uniqueKeysWithValues: scopedEvents.map {
          (
            $0.id,
            DecisionAuditTrailPayloadPresentation(
              payloadJSON: $0.payloadJSON,
              decoder: decoder
            )
          )
        }
      )
    )
  }

  func waitForIdle() async {}
}

private struct SessionDecisionAuditInput: Equatable, Sendable {
  let sessionID: String
  let decisionIDs: Set<String>
  let agentIDs: Set<String>
  let taskIDs: Set<String>

  init(sessionID: String, decisionItems: [DecisionPresentationSnapshot]) {
    self.sessionID = sessionID
    decisionIDs = Set(decisionItems.map(\.id))
    agentIDs = Set(decisionItems.compactMap(\.agentID))
    taskIDs = Set(decisionItems.compactMap(\.taskID))
  }

  @MainActor
  init(sessionID: String, decisions: [Decision]) {
    self.init(
      sessionID: sessionID,
      decisionItems: decisions.map(DecisionPresentationSnapshot.init)
    )
  }
}

private struct SessionDecisionAuditOutput: Equatable, Sendable {
  static let empty = Self(events: [], payloadPresentations: [:])

  let events: [SupervisorEventSnapshot]
  let payloadPresentations: [String: DecisionAuditTrailPayloadPresentation]
}

private struct SessionDecisionAuditPayloadScope {
  let sessionID: String?
  let agentID: String?
  let taskID: String?
  let decisionID: String?

  init(payloadJSON: String) {
    guard let data = payloadJSON.data(using: .utf8) else {
      sessionID = nil
      agentID = nil
      taskID = nil
      decisionID = nil
      return
    }
    let object = try? JSONSerialization.jsonObject(with: data)
    sessionID = Self.firstString(
      forKeys: ["sessionID", "sessionId", "session_id"],
      in: object
    )
    agentID = Self.firstString(
      forKeys: ["agentID", "agentId", "agent_id"],
      in: object
    )
    taskID = Self.firstString(
      forKeys: ["taskID", "taskId", "task_id"],
      in: object
    )
    decisionID = Self.firstString(
      forKeys: ["decisionID", "decisionId", "decision_id"],
      in: object
    )
  }

  func matchesExplicitSessionScope(
    sessionID expectedSessionID: String,
    decisionIDs: Set<String>,
    agentIDs: Set<String>,
    taskIDs: Set<String>
  ) -> Bool {
    let sessionMatches = self.sessionID.map { $0 == expectedSessionID }
    if sessionMatches == false {
      return false
    }

    let decisionMatches = decisionID.map { decisionIDs.contains($0) }
    if decisionMatches == false {
      return false
    }

    let taskMatches = taskID.map { taskIDs.contains($0) }
    if taskMatches == false {
      return false
    }

    let agentMatches = agentID.map { agentIDs.contains($0) }
    if agentMatches == false {
      return false
    }

    return decisionMatches == true
      || taskMatches == true
      || agentMatches == true
      || sessionMatches == true
  }

  private static func firstString(forKeys keys: [String], in object: Any?) -> String? {
    if let dictionary = object as? [String: Any] {
      for key in keys {
        if let value = stringValue(dictionary[key]) {
          return value
        }
      }
      for value in dictionary.values {
        if let nested = firstString(forKeys: keys, in: value) {
          return nested
        }
      }
    }
    if let array = object as? [Any] {
      for value in array {
        if let nested = firstString(forKeys: keys, in: value) {
          return nested
        }
      }
    }
    return nil
  }

  private static func stringValue(_ value: Any?) -> String? {
    guard let value = value as? String, !value.isEmpty else {
      return nil
    }
    return value
  }
}
