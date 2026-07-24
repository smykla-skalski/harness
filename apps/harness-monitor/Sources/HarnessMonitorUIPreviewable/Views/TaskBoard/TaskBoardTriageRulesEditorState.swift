import Foundation
import HarnessMonitorKit
import Observation

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

  static let jsonEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }()

  static let jsonDecoder = JSONDecoder()

  func decodedCandidate() -> TriageRuleSetV1? {
    guard let data = draftText.data(using: .utf8) else { return nil }
    return try? Self.jsonDecoder.decode(TriageRuleSetV1.self, from: data)
  }

  func applyLoad(
    draft: TriageRuleSetDraft?,
    activeRevision: Int64?,
    revisions: [TriageRuleSetRevisionSummary],
    audit: [TriageRuleSetAuditEntry]
  ) {
    if let draft {
      draftRevision = draft.revision
      draftText = Self.encodedText(draft.rules) ?? draftText
    } else {
      draftRevision = nil
    }
    self.activeRevision = activeRevision
    self.revisions = revisions
    self.audit = audit
    hasLoaded = true
  }

  static func encodedText(_ rules: TriageRuleSetV1) -> String? {
    guard let data = try? jsonEncoder.encode(rules) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
