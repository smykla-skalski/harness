import CryptoKit
import Foundation

extension PreviewHarnessClientState {
  private struct PreviewBuiltInV1Outcome {
    let verdict: TriageVerdict
    let reasonCode: TriageReasonCode
    let reasonDetail: String?
  }

  private static let needsInfoLabels: Set<String> = ["needs-info", "triage/needs-info"]
  private static let previewEvaluatorVersion: UInt32 = 1

  private static func canonicalizeLabels(_ tags: [String]) -> [String] {
    var labels = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { !$0.isEmpty }
    labels.sort()
    var deduped: [String] = []
    for label in labels where deduped.last != label {
      deduped.append(label)
    }
    return deduped
  }

  /// Smallest port of the daemon's `evaluate_builtin_v1` check table.
  private static func evaluatePreviewBuiltInV1(_ tags: [String]) -> PreviewBuiltInV1Outcome {
    let labels = canonicalizeLabels(tags)
    if let label = labels.first(where: { needsInfoLabels.contains($0) }) {
      return PreviewBuiltInV1Outcome(
        verdict: .undecided, reasonCode: .needsInfoLabel, reasonDetail: label)
    }
    if labels.isEmpty {
      return PreviewBuiltInV1Outcome(
        verdict: .undecided, reasonCode: .noMeaningfulLabels, reasonDetail: nil)
    }
    return PreviewBuiltInV1Outcome(verdict: .todo, reasonCode: .meaningfulLabel, reasonDetail: nil)
  }

  private static let fingerprintDomain = Array(
    "harness.task_board.triage.evidence_fingerprint.v1".utf8)

  private static func appendHashPart(_ digest: inout SHA256, _ value: [UInt8]) {
    let length = UInt64(value.count).bigEndian
    withUnsafeBytes(of: length) { digest.update(bufferPointer: $0) }
    value.withUnsafeBufferPointer { digest.update(bufferPointer: UnsafeRawBufferPointer($0)) }
  }

  private static func appendOptionalHashPart(_ digest: inout SHA256, _ value: String?) {
    let flag: [UInt8] = [value != nil ? 1 : 0]
    flag.withUnsafeBufferPointer { digest.update(bufferPointer: UnsafeRawBufferPointer($0)) }
    if let value {
      appendHashPart(&digest, Array(value.utf8))
    }
  }

  private static func sortedDeduped(_ values: [String]) -> [String] {
    var sorted = values.sorted()
    var deduped: [String] = []
    for value in sorted where deduped.last != value {
      deduped.append(value)
    }
    sorted = deduped
    return sorted
  }

  /// Matches `evidence_fingerprint` field-for-field: same domain, order,
  /// length-prefixing, and `sha256:<64 lowercase hex>` shape, so a preview
  /// decision record is a valid server-shaped fixture.
  private static func evidenceFingerprint(_ item: TaskBoardItem) -> String {
    var digest = SHA256()
    appendHashPart(&digest, fingerprintDomain)
    appendHashPart(&digest, Array(item.title.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    appendHashPart(&digest, Array(item.body.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    appendHashPart(&digest, Array(item.priority.rawValue.utf8))
    for label in canonicalizeLabels(item.tags) {
      appendHashPart(&digest, Array(label.utf8))
    }
    appendHashPart(&digest, Array(item.kind.rawValue.utf8))
    appendOptionalHashPart(&digest, item.executionRepository)
    appendOptionalHashPart(&digest, item.projectId)
    for targetType in sortedDeduped(item.targetProjectTypes) {
      appendHashPart(&digest, Array(targetType.utf8))
    }
    appendOptionalHashPart(&digest, item.importedFromProvider?.rawValue)
    let refs = item.externalRefs.map { "\($0.provider.rawValue)#\($0.externalId)" }
    for reference in sortedDeduped(refs) {
      appendHashPart(&digest, Array(reference.utf8))
    }
    let hex = digest.finalize().map { String(format: "%02x", $0) }.joined()
    return "sha256:\(hex)"
  }

  /// Mirrors `ensure_current_triage_decision_in_tx`'s cause selection: an
  /// evaluator mismatch outranks a fingerprint change, and a congruent
  /// evaluator/fingerprint pair is never re-decided.
  func ensurePreviewTriageDecision(
    for item: TaskBoardItem
  ) -> TaskBoardTriageDecisionRecord {
    let outcome = Self.evaluatePreviewBuiltInV1(item.tags)
    let fingerprint = Self.evidenceFingerprint(item)
    let existing = taskBoardTriageDecisionsByItemID[item.id]?.first
    let cause: TriageCause
    if let existing {
      if existing.evaluatorIdentity != Self.builtinV1EvaluatorIdentity
        || existing.evaluatorVersion != Self.previewEvaluatorVersion
      {
        cause = .activeEvaluatorChanged
      } else if existing.evidenceFingerprint != fingerprint {
        cause = .fingerprintChanged
      } else {
        return existing
      }
    } else {
      cause = .initial
    }
    let nextGeneration = (existing?.generation ?? 0) + 1
    let decisionHex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let decision = TaskBoardTriageDecisionRecord(
      decisionId: "triage-\(decisionHex)",
      itemId: item.id,
      generation: nextGeneration,
      verdict: outcome.verdict,
      reasonCode: outcome.reasonCode,
      reasonDetail: outcome.reasonDetail,
      evaluatorIdentity: Self.builtinV1EvaluatorIdentity,
      evaluatorVersion: Self.previewEvaluatorVersion,
      evidenceFingerprint: fingerprint,
      cause: cause,
      decidedAt: Self.mutationTimestamp,
      supersededAt: nil
    )
    if var priorDecisions = taskBoardTriageDecisionsByItemID[item.id], !priorDecisions.isEmpty {
      priorDecisions[0].supersededAt = Self.mutationTimestamp
      taskBoardTriageDecisionsByItemID[item.id] = [decision] + priorDecisions
    } else {
      taskBoardTriageDecisionsByItemID[item.id] = [decision]
    }
    return decision
  }
}
