import Foundation

/// The exact `PolicyReasonCode` variants the Rust daemon accepts, in serde
/// snake_case. Inspector commit paths and node templates must only ever write
/// one of these strings; anything else breaks save/simulate on the daemon.
/// Keep this list byte-equal to the Rust enum's raw values.
public enum PolicyCanvasReasonCode {
  public static let defaultAllow = "default_allow"
  public static let autoMergeAllowed = "auto_merge_allowed"
  public static let missingMergeEvidence = "missing_merge_evidence"
  public static let checksNotGreen = "checks_not_green"
  public static let branchProtectionBlocked = "branch_protection_blocked"
  public static let reviewerNotApproved = "reviewer_not_approved"
  public static let unresolvedRequestedChanges = "unresolved_requested_changes"
  public static let protectedPathTouched = "protected_path_touched"
  public static let riskAboveThreshold = "risk_above_threshold"
  public static let humanRequired = "human_required"
  public static let dryRunRequired = "dry_run_required"

  /// Every accepted raw value. A reason-code string the inspector writes must
  /// be a member of this set.
  public static let allValid: Set<String> = [
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

  /// Stable display order for reason-code pickers, matching the declaration
  /// order so the inspector branch list does not reshuffle between renders
  /// (a `Set` iteration order would).
  public static let ordered: [String] = [
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

  /// Human-facing label for a reason code: underscores become spaces so a
  /// picker reads "reviewer not approved", not the raw daemon token.
  public static func displayName(_ code: String) -> String {
    code.replacingOccurrences(of: "_", with: " ")
  }
}
