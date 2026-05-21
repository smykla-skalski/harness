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

  @ObservationIgnored var inspectorRowCache:
    [SessionDecisionInspectorRowKey: SessionDecisionInspectorRows] = [:]
  @ObservationIgnored var inspectorRowKeyOrder: [SessionDecisionInspectorRowKey] = []
  @ObservationIgnored nonisolated(unsafe) var filterTask: Task<Void, Never>?
  @ObservationIgnored nonisolated(unsafe) var inspectorRowTask: Task<Void, Never>?
  @ObservationIgnored var latestFilterInput: SessionDecisionFilterInput?
  @ObservationIgnored var latestInspectorRowKey: SessionDecisionInspectorRowKey?
  @ObservationIgnored var inspectorRowGeneration: UInt64 = 0
  @ObservationIgnored var auditReloadGeneration: UInt64 = 0

  static let cacheLimit = 32
  static let filterSignposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "perf/session-decision-filter"
  )
  static let inspectorSignposter = OSSignposter(
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
      let contextCount = rows.contextRows.count
      let historyCount = rows.historyRows.count
      Self.inspectorSignposter.endInterval(
        "session_decision_inspector.compute",
        computeInterval,
        "contextRows=\(contextCount, privacy: .public) historyRows=\(historyCount, privacy: .public)"
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

  func applyAuditReloadOutput(
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

  func storeInspectorRows(
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
