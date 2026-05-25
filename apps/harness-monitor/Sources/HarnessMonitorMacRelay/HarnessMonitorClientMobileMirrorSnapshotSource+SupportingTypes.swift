import Foundation
import HarnessMonitorCore
import HarnessMonitorKit

struct MobileMirrorSecretRedactor {
  private struct Rule {
    var expression: NSRegularExpression
    var template: String
  }

  private struct RawRule {
    var pattern: String
    var options: NSRegularExpression.Options
    var template: String
  }

  private let rules: [Rule]

  init() {
    rules = Self.rawRules.map { rule in
      guard
        let expression = try? NSRegularExpression(
          pattern: rule.pattern,
          options: rule.options
        )
      else {
        fatalError("Invalid redaction rule pattern: \(rule.pattern)")
      }
      return Rule(expression: expression, template: rule.template)
    }
  }

  func redact(_ value: String) -> String {
    guard !value.isEmpty else {
      return value
    }
    return rules.reduce(value) { partial, rule in
      let range = NSRange(partial.startIndex..<partial.endIndex, in: partial)
      return rule.expression.stringByReplacingMatches(
        in: partial,
        options: [],
        range: range,
        withTemplate: rule.template
      )
    }
  }

  private static let rawRules: [RawRule] = [
      .init(
        pattern:
          "(?i)(\\b(?:aws_secret_access_key|aws_access_key_id|github_token|gh_token"
          + "|gitlab_token|openai_api_key|anthropic_api_key|api[_-]?key"
          + "|access[_-]?token|refresh[_-]?token|auth[_-]?token|id[_-]?token"
          + "|client[_-]?secret|private[_-]?key|secret|password|passwd|pwd)"
          + "\\b\\s*[:=]\\s*)(\"[^\"]*\"|'[^']*'|[^\\s,;]+)",
        options: [],
        template: "$1[redacted]"
      ),
      .init(
        pattern: "(?i)\\bBearer\\s+[A-Za-z0-9._~+/=-]{8,}",
        options: [],
        template: "Bearer [redacted]"
      ),
      .init(
        pattern: "(?i)(https?://)[^\\s/@]+:[^\\s/@]+@",
        options: [],
        template: "$1[redacted]@"
      ),
      .init(
        pattern: "\\bgithub_pat_[A-Za-z0-9_]{20,}\\b",
        options: [],
        template: "[redacted]"
      ),
      .init(
        pattern: "\\bgh[pousr]_[A-Za-z0-9_]{20,}\\b",
        options: [],
        template: "[redacted]"
      ),
      .init(
        pattern: "\\bglpat-[A-Za-z0-9_-]{20,}\\b",
        options: [],
        template: "[redacted]"
      ),
      .init(
        pattern: "\\bsk-[A-Za-z0-9]{20,}\\b",
        options: [],
        template: "[redacted]"
      ),
      .init(
        pattern: "\\bxox[baprs]-[A-Za-z0-9-]{20,}\\b",
        options: [],
        template: "[redacted]"
      ),
      .init(
        pattern: "\\bAKIA[0-9A-Z]{16}\\b",
        options: [],
        template: "[redacted]"
      ),
      .init(
        pattern:
          "-----BEGIN [^-]*(?:PRIVATE KEY|SECRET|TOKEN)[\\s\\S]*?-----END [^-]*-----",
        options: [.caseInsensitive],
        template: "[redacted]"
      ),
    ]
}

extension MobileCommandRecord {
  func redactingMobileMirrorSecrets(
    using redactor: MobileMirrorSecretRedactor
  ) -> MobileCommandRecord {
    var command = self
    command.title = redactor.redact(command.title)
    command.confirmationText = redactor.redact(command.confirmationText)
    command.auditReason = command.auditReason.map { redactor.redact($0) }
    command.payload = command.payload.mapValues { redactor.redact($0) }
    command.receipt = command.receipt?.redactingMobileMirrorSecrets(using: redactor)
    return command
  }
}

extension MobileCommandReceipt {
  func redactingMobileMirrorSecrets(
    using redactor: MobileMirrorSecretRedactor
  ) -> MobileCommandReceipt {
    var receipt = self
    receipt.message = redactor.redact(receipt.message)
    return receipt
  }
}

struct MobileRelayTaskBoardFetchResult: Sendable {
  var items: [TaskBoardItem]
  var mobileItems: [MobileTaskBoardSummary]?
  var attentionFallback: [MobileAttentionItem]

  init(
    items: [TaskBoardItem],
    mobileItems: [MobileTaskBoardSummary]? = nil,
    attentionFallback: [MobileAttentionItem] = []
  ) {
    self.items = items
    self.mobileItems = mobileItems
    self.attentionFallback = attentionFallback
  }
}

struct MobileRelaySessionDetailFetchResult: Sendable {
  var detailsBySessionID: [String: SessionDetail]
  var failedSessionIDs: Set<String>
  var attentionFallback: [MobileAttentionItem]
}

struct MobileRelaySessionDetailFetchOutcome: Sendable {
  var sessionID: String
  var detail: SessionDetail?
}

struct MobileRelayManagedAgentsFetchResult: Sendable {
  var agentsBySessionID: [String: [ManagedAgentSnapshot]]
  var failedSessionIDs: Set<String>
  var attentionFallback: [MobileAttentionItem]
}

struct MobileRelayManagedAgentsFetchOutcome: Sendable {
  var sessionID: String
  var agents: [ManagedAgentSnapshot]?
}

extension ManagedAgentSnapshot {
  var displayTitle: String {
    switch self {
    case .terminal(let snapshot):
      snapshot.agentId
    case .codex(let snapshot):
      snapshot.displayName ?? snapshot.runId
    case .acp(let snapshot):
      snapshot.displayName
    }
  }
}

struct MobileRelayReviewFetchResult: Sendable {
  var reviews: [ReviewItem]
  var mobileReviews: [MobileReviewSummary]
  var attentionFallback: [MobileAttentionItem]

  init(
    reviews: [ReviewItem],
    mobileReviews: [MobileReviewSummary],
    attentionFallback: [MobileAttentionItem] = []
  ) {
    self.reviews = reviews
    self.mobileReviews = mobileReviews
    self.attentionFallback = attentionFallback
  }
}

struct MobileRelayReviewEnrichment: Sendable {
  var review: ReviewItem
  var filesResponse: ReviewsFilesListResponse?
  var timelineResponse: ReviewsTimelineResponse?
}

func batches<Element>(_ values: [Element], size: Int) -> [[Element]] {
  guard size > 0, !values.isEmpty else {
    return []
  }
  var result: [[Element]] = []
  result.reserveCapacity((values.count + size - 1) / size)
  var start = values.startIndex
  while start < values.endIndex {
    let end = values.index(start, offsetBy: size, limitedBy: values.endIndex) ?? values.endIndex
    result.append(Array(values[start..<end]))
    start = end
  }
  return result
}
