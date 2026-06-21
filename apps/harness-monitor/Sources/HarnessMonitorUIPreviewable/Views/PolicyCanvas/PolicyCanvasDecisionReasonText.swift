import Foundation

/// Human-readable explanation for a daemon policy reason code, shown under the
/// verdict in the decision matrix and scenario rows.
///
/// Returns `nil` when the reason would only restate the verdict the pill already
/// shows - an allow whose reason is "default allow", a needs-human whose reason
/// is "human required", a dry-run whose reason is "dry run required". The row
/// then carries the *why* only when it adds something the verdict does not, which
/// is what keeps the matrix scannable instead of echoing each verdict twice.
enum PolicyCanvasDecisionReason {
  /// Reason codes that say nothing the verdict pill does not already say. Each
  /// pairs one-to-one with its verdict (`default_allow` only ever accompanies an
  /// allow, and so on), so suppressing them needs no verdict context.
  private static let restatesVerdict: Set<String> = [
    "default_allow",
    "human_required",
    "dry_run_required",
  ]

  /// Short, user-facing phrase for each daemon reason code that carries real
  /// information. Unknown codes fall back to the raw code with underscores turned
  /// into spaces, so a new daemon code degrades to readable text rather than
  /// vanishing.
  private static let phrases: [String: String] = [
    "auto_merge_allowed": "Auto-merge rule passed",
    "missing_merge_evidence": "No merge evidence yet",
    "checks_not_green": "Checks not green",
    "branch_protection_blocked": "Branch protection blocked",
    "reviewer_not_approved": "Not approved by a reviewer",
    "unresolved_requested_changes": "Unresolved change requests",
    "protected_path_touched": "Touches a protected path",
    "risk_above_threshold": "Risk above threshold",
  ]

  /// The explanation to show under the verdict, or `nil` to show nothing.
  static func explanation(reasonCode: String) -> String? {
    let code = reasonCode.trimmingCharacters(in: .whitespacesAndNewlines)
    if code.isEmpty || restatesVerdict.contains(code) {
      return nil
    }
    return phrases[code] ?? code.replacingOccurrences(of: "_", with: " ")
  }
}
