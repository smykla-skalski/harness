import Foundation

public enum AutomationPolicyEventOutcome: String, Codable, CaseIterable, Sendable {
  case matched
  case skipped
  case denied
  case failed

  public var title: String {
    switch self {
    case .matched: "Matched"
    case .skipped: "Skipped"
    case .denied: "Denied"
    case .failed: "Failed"
    }
  }
}

public struct AutomationPolicyEventRecord: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var occurredAt: Date
  public var source: AutomationPolicyEventSource
  public var outcome: AutomationPolicyEventOutcome
  public var policyID: String?
  public var policyName: String?
  public var reason: String?
  public var summary: String
  public var contentKinds: Set<AutomationClipboardContentKind>
  public var declaredTypes: [String]
  public var detectedContentType: String?
  public var sourceApplication: AutomationSourceApplication?
  public var actions: [AutomationPolicyAction]
  public var postprocessors: [AutomationPolicyPostprocessor]
  public var executedActions: [AutomationPolicyAction]?
  public var skippedActions: [AutomationPolicyAction]?
  public var executedPostprocessors: [AutomationPolicyPostprocessor]?
  public var trigger: String
  public var textPreview: String?
  public var filePaths: [String]

  public init(
    id: UUID = UUID(),
    occurredAt: Date = Date(),
    source: AutomationPolicyEventSource,
    outcome: AutomationPolicyEventOutcome,
    policyID: String?,
    policyName: String?,
    reason: String?,
    summary: String,
    contentKinds: Set<AutomationClipboardContentKind>,
    declaredTypes: [String],
    detectedContentType: String?,
    sourceApplication: AutomationSourceApplication?,
    actions: [AutomationPolicyAction],
    postprocessors: [AutomationPolicyPostprocessor],
    executedActions: [AutomationPolicyAction]? = nil,
    skippedActions: [AutomationPolicyAction]? = nil,
    executedPostprocessors: [AutomationPolicyPostprocessor]? = nil,
    trigger: String,
    textPreview: String? = nil,
    filePaths: [String] = []
  ) {
    self.id = id
    self.occurredAt = occurredAt
    self.source = source
    self.outcome = outcome
    self.policyID = policyID
    self.policyName = policyName
    self.reason = reason
    self.summary = summary
    self.contentKinds = contentKinds
    self.declaredTypes = declaredTypes
    self.detectedContentType = detectedContentType
    self.sourceApplication = sourceApplication
    self.actions = actions
    self.postprocessors = postprocessors
    self.executedActions = executedActions
    self.skippedActions = skippedActions
    self.executedPostprocessors = executedPostprocessors
    self.trigger = trigger
    self.textPreview = textPreview
    self.filePaths = filePaths
  }
}

final class AutomationPolicyEventStore {
  private let fileURL: URL
  private let maxItems: Int
  private let fileManager: FileManager
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(
    directoryURL: URL,
    maxItems: Int = 120,
    fileManager: FileManager = .default
  ) {
    fileURL = directoryURL.appendingPathComponent("automation-events.json")
    self.maxItems = max(0, maxItems)
    self.fileManager = fileManager
    encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
  }

  func load() -> [AutomationPolicyEventRecord] {
    guard
      let data = try? Data(contentsOf: fileURL),
      let events = try? decoder.decode([AutomationPolicyEventRecord].self, from: data)
    else {
      return []
    }
    return Array(events.prefix(maxItems))
  }

  func record(_ event: AutomationPolicyEventRecord) -> [AutomationPolicyEventRecord] {
    var events = load()
    events.insert(event, at: 0)
    events = Array(events.prefix(maxItems))
    write(events)
    return events
  }

  func clear() -> [AutomationPolicyEventRecord] {
    write([])
    return []
  }

  private func write(_ events: [AutomationPolicyEventRecord]) {
    do {
      try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let data = try encoder.encode(events)
      try data.write(to: fileURL, options: .atomic)
    } catch {
      _ = error
      // Event persistence must never block clipboard policy evaluation.
    }
  }
}
