import Foundation

/// The exact `PolicyReasonCode` variants the Rust daemon accepts, in serde
/// snake_case. Inspector commit paths and node templates must only ever write
/// one of these strings; anything else breaks save/simulate on the daemon.
/// Keep this list byte-equal to the Rust enum's raw values.
enum PolicyCanvasReasonCode {
  static let defaultAllow = "default_allow"
  static let autoMergeAllowed = "auto_merge_allowed"
  static let missingMergeEvidence = "missing_merge_evidence"
  static let checksNotGreen = "checks_not_green"
  static let branchProtectionBlocked = "branch_protection_blocked"
  static let reviewerNotApproved = "reviewer_not_approved"
  static let unresolvedRequestedChanges = "unresolved_requested_changes"
  static let protectedPathTouched = "protected_path_touched"
  static let riskAboveThreshold = "risk_above_threshold"
  static let humanRequired = "human_required"
  static let dryRunRequired = "dry_run_required"

  /// Every accepted raw value. A reason-code string the inspector writes must
  /// be a member of this set.
  static let allValid: Set<String> = [
    defaultAllow,
    autoMergeAllowed,
    missingMergeEvidence,
    checksNotGreen,
    branchProtectionBlocked,
    reviewerNotApproved,
    unresolvedRequestedChanges,
    protectedPathTouched,
    riskAboveThreshold,
    humanRequired,
    dryRunRequired,
  ]
}
