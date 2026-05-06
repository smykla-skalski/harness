import Foundation
import HarnessMonitorKit

enum SessionTimelineFilterPersistenceMode: String, CaseIterable, Identifiable, Sendable {
  case sessionWindow
  case application
  case ephemeral

  var id: String { rawValue }

  var label: String {
    switch self {
    case .sessionWindow:
      "Per Window & Session"
    case .application:
      "App-Wide"
    case .ephemeral:
      "Do Not Remember"
    }
  }
}

enum SessionTimelineSearchScope: String, CaseIterable, Identifiable, Sendable {
  case all
  case summary
  case source
  case agent
  case task
  case properties

  var id: String { rawValue }

  var label: String {
    switch self {
    case .all:
      "All fields"
    case .summary:
      "Summary"
    case .source:
      "Event type"
    case .agent:
      "Agent"
    case .task:
      "Task"
    case .properties:
      "Properties"
    }
  }

  var systemImage: String {
    switch self {
    case .all:
      "text.magnifyingglass"
    case .summary:
      "text.alignleft"
    case .source:
      "square.stack.3d.up"
    case .agent:
      "person.crop.circle"
    case .task:
      "checklist"
    case .properties:
      "curlybraces"
    }
  }
}

enum SessionTimelineSemanticProperty: String, CaseIterable, Identifiable, Sendable {
  case linkedDecision
  case toolCall
  case agent
  case task
  case capabilityTags
  case stopReason
  case decisionAction

  var id: String { rawValue }

  var label: String {
    switch self {
    case .linkedDecision:
      "Linked decision"
    case .toolCall:
      "Tool call"
    case .agent:
      "Agent"
    case .task:
      "Task"
    case .capabilityTags:
      "Capability tags"
    case .stopReason:
      "Stop reason"
    case .decisionAction:
      "Decision action"
    }
  }
}

enum SessionTimelineFilterDefaults {
  static let persistenceModeKey = "harness.session.timeline.filters.persistence-mode"
  static let appStateKey = "harness.session.timeline.filters.app-state"
  static let sceneRegistryKey = "harness.session.timeline.filters.scene-registry"

  static let defaultPersistenceMode = SessionTimelineFilterPersistenceMode.sessionWindow
}

struct SessionTimelineFilterState: Equatable, Sendable {
  static let signalEventKinds: Set<String> = [
    "signal_sent", "signal_received", "signal_acknowledged",
  ]

  var query: String = ""
  var searchScope: SessionTimelineSearchScope = .all
  var tones: Set<SessionTimelineTone> = []
  var eventTypes: Set<String> = []
  var agents: Set<String> = []
  var tasks: Set<String> = []
  var decisionSeverities: Set<String> = []
  var semanticProperties: Set<SessionTimelineSemanticProperty> = []
  var rawPayloadKeys: Set<String> = []

  init() {}

  var trimmedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var isEmpty: Bool {
    trimmedQuery.isEmpty
      && tones.isEmpty
      && eventTypes.isEmpty
      && agents.isEmpty
      && tasks.isEmpty
      && decisionSeverities.isEmpty
      && semanticProperties.isEmpty
      && rawPayloadKeys.isEmpty
  }

  var activeFilterCount: Int {
    let queryCount = trimmedQuery.isEmpty ? 0 : 1
    return queryCount
      + tones.count
      + eventTypes.count
      + agents.count
      + tasks.count
      + decisionSeverities.count
      + semanticProperties.count
      + rawPayloadKeys.count
  }

  var signature: String {
    [
      "query=\(trimmedQuery)",
      "scope=\(searchScope.rawValue)",
      "tones=\(Self.signatureValue(tones.map(\.rawValue)))",
      "types=\(Self.signatureValue(eventTypes))",
      "agents=\(Self.signatureValue(agents))",
      "tasks=\(Self.signatureValue(tasks))",
      "severities=\(Self.signatureValue(decisionSeverities))",
      "semantic=\(Self.signatureValue(semanticProperties.map(\.rawValue)))",
      "keys=\(Self.signatureValue(rawPayloadKeys))",
    ]
    .joined(separator: ";")
  }

  mutating func clear() {
    self = .init()
  }

  mutating func clearTones() {
    tones = []
  }

  mutating func toggleTone(_ tone: SessionTimelineTone) {
    Self.toggleMembership(of: tone, in: &tones)
  }

  var signalPresetActive: Bool {
    Self.signalEventKinds.isSubset(of: eventTypes)
  }

  mutating func toggleSignalPreset() {
    if signalPresetActive {
      eventTypes.subtract(Self.signalEventKinds)
    } else {
      eventTypes.formUnion(Self.signalEventKinds)
    }
  }

  mutating func toggleEventType(_ rawValue: String) {
    Self.toggleMembership(of: rawValue, in: &eventTypes)
  }

  mutating func toggleAgent(_ rawValue: String) {
    Self.toggleMembership(of: rawValue, in: &agents)
  }

  mutating func toggleTask(_ rawValue: String) {
    Self.toggleMembership(of: rawValue, in: &tasks)
  }

  mutating func toggleDecisionSeverity(_ severity: DecisionSeverity) {
    Self.toggleMembership(of: severity.rawValue, in: &decisionSeverities)
  }

  mutating func toggleSemanticProperty(_ property: SessionTimelineSemanticProperty) {
    Self.toggleMembership(of: property, in: &semanticProperties)
  }

  mutating func toggleRawPayloadKey(_ rawValue: String) {
    Self.toggleMembership(of: rawValue, in: &rawPayloadKeys)
  }

  var activeAdvancedFilterCount: Int {
    eventTypes.count
      + agents.count
      + tasks.count
      + decisionSeverities.count
      + semanticProperties.count
      + rawPayloadKeys.count
  }

  func removingTones() -> Self {
    var copy = self
    copy.tones = []
    return copy
  }

  func removingEventTypes() -> Self {
    var copy = self
    copy.eventTypes = []
    return copy
  }

  func removingAgents() -> Self {
    var copy = self
    copy.agents = []
    return copy
  }

  func removingTasks() -> Self {
    var copy = self
    copy.tasks = []
    return copy
  }

  func removingDecisionSeverities() -> Self {
    var copy = self
    copy.decisionSeverities = []
    return copy
  }

  func removingSemanticProperties() -> Self {
    var copy = self
    copy.semanticProperties = []
    return copy
  }

  func removingRawPayloadKeys() -> Self {
    var copy = self
    copy.rawPayloadKeys = []
    return copy
  }

  func encodedString() -> String? {
    try? Self.encoder.encodeToString(storage)
  }

  static func decode(from rawValue: String) -> Self? {
    guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    guard
      let data = rawValue.data(using: .utf8),
      let storage = try? decoder.decode(SessionTimelineFilterStateStorage.self, from: data)
    else {
      return nil
    }
    return Self(storage: storage)
  }

  fileprivate var storage: SessionTimelineFilterStateStorage {
    SessionTimelineFilterStateStorage(
      query: trimmedQuery,
      searchScope: searchScope.rawValue,
      tones: tones.map(\.rawValue).sorted(),
      eventTypes: eventTypes.sorted(),
      agents: agents.sorted(),
      tasks: tasks.sorted(),
      decisionSeverities: decisionSeverities.sorted(),
      semanticProperties: semanticProperties.map(\.rawValue).sorted(),
      rawPayloadKeys: rawPayloadKeys.sorted()
    )
  }

  fileprivate init(storage: SessionTimelineFilterStateStorage) {
    query = storage.query
    searchScope = SessionTimelineSearchScope(rawValue: storage.searchScope) ?? .all
    tones = Set(storage.tones.compactMap(SessionTimelineTone.init(rawValue:)))
    eventTypes = Set(storage.eventTypes)
    agents = Set(storage.agents)
    tasks = Set(storage.tasks)
    decisionSeverities = Set(storage.decisionSeverities)
    semanticProperties = Set(
      storage.semanticProperties.compactMap(SessionTimelineSemanticProperty.init(rawValue:))
    )
    rawPayloadKeys = Set(storage.rawPayloadKeys)
  }

  fileprivate static let encoder = StableFilterStateEncoder()
  fileprivate static let decoder = JSONDecoder()

  private static func toggleMembership<Value: Hashable>(
    of value: Value,
    in set: inout Set<Value>
  ) {
    if set.contains(value) {
      set.remove(value)
    } else {
      set.insert(value)
    }
  }

  private static func signatureValue<S: Sequence>(_ values: S) -> String where S.Element == String {
    values.sorted().joined(separator: ",")
  }
}

struct SessionTimelineStoredFilterRegistry: Equatable, Sendable {
  var statesBySessionID: [String: SessionTimelineFilterState] = [:]

  func state(for sessionID: String) -> SessionTimelineFilterState? {
    statesBySessionID[sessionID]
  }

  mutating func set(_ state: SessionTimelineFilterState, for sessionID: String) {
    if state.isEmpty {
      statesBySessionID.removeValue(forKey: sessionID)
    } else {
      statesBySessionID[sessionID] = state
    }
  }

  func encodedString() -> String? {
    let storage = SessionTimelineStoredFilterRegistryStorage(
      statesBySessionID: statesBySessionID.mapValues(\.storage)
    )
    return try? SessionTimelineFilterState.encoder.encodeToString(storage)
  }

  static func decode(from rawValue: String) -> Self {
    guard
      !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let data = rawValue.data(using: .utf8),
      let storage = try? SessionTimelineFilterState.decoder.decode(
        SessionTimelineStoredFilterRegistryStorage.self,
        from: data
      )
    else {
      return .init()
    }
    let statesBySessionID = storage.statesBySessionID.mapValues(
      SessionTimelineFilterState.init(storage:)
    )
    return Self(
      statesBySessionID: statesBySessionID
    )
  }
}

private struct SessionTimelineFilterStateStorage: Codable {
  let query: String
  let searchScope: String
  let tones: [String]
  let eventTypes: [String]
  let agents: [String]
  let tasks: [String]
  let decisionSeverities: [String]
  let semanticProperties: [String]
  let rawPayloadKeys: [String]
}

private struct SessionTimelineStoredFilterRegistryStorage: Codable {
  let statesBySessionID: [String: SessionTimelineFilterStateStorage]
}

private struct StableFilterStateEncoder {
  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()

  func encodeToString<Value: Encodable>(_ value: Value) throws -> String {
    let data = try encoder.encode(value)
    guard let string = String(data: data, encoding: .utf8) else {
      throw EncodingError.invalidValue(
        value,
        .init(codingPath: [], debugDescription: "Failed to encode filter state as UTF-8")
      )
    }
    return string
  }
}
