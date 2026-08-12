import Foundation
import HarnessMonitorKit
import Observation

struct TaskBoardTriageRulesEditorLoadProjection: Equatable, Sendable {
  static let historyLimit: UInt32 = 10

  let draftText: String?
  let draftRevision: Int64?
  let activeRevision: Int64?
  let revisions: [TriageRuleSetRevisionSummary]
  let audit: [TriageRuleSetAuditEntry]

  init(
    draft: TriageRuleSetDraft?,
    revisions: [TriageRuleSetRevisionSummary],
    audit: [TriageRuleSetAuditEntry]
  ) {
    draftText = draft.flatMap { Self.encodedText($0.rules) }
    draftRevision = draft?.revision
    activeRevision = revisions.first(where: { $0.status == .active })?.revision
    let limit = Int(Self.historyLimit)
    self.revisions = Array(revisions.prefix(limit))
    self.audit = Array(audit.prefix(limit))
  }

  static func encodedText(_ rules: TriageRuleSetV1) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(rules) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}

@MainActor
@Observable
final class TaskBoardTriageRulesEditorState {
  var draftText = ""
  var draftRevision: Int64?
  var activeRevision: Int64?
  var validation: TriageRuleSetValidationReport?
  var previewDiff: [TriageRuleSetPreviewDiffEntry]?
  var revisions: [TriageRuleSetRevisionSummary] = []
  var audit: [TriageRuleSetAuditEntry] = []
  var isBusy = false
  var statusMessage: String?
  var hasLoaded = false

  static let jsonDecoder = JSONDecoder()

  func decodedCandidate() -> TriageRuleSetV1? {
    guard let data = draftText.data(using: .utf8) else { return nil }
    return try? Self.jsonDecoder.decode(TriageRuleSetV1.self, from: data)
  }

  func applyLoad(_ projection: TaskBoardTriageRulesEditorLoadProjection) {
    if let draftRevision = projection.draftRevision {
      self.draftRevision = draftRevision
      draftText = projection.draftText ?? draftText
    } else {
      draftRevision = nil
    }
    activeRevision = projection.activeRevision
    revisions = projection.revisions
    audit = projection.audit
    hasLoaded = true
  }

  nonisolated static func encodedText(_ rules: TriageRuleSetV1) -> String? {
    TaskBoardTriageRulesEditorLoadProjection.encodedText(rules)
  }
}
