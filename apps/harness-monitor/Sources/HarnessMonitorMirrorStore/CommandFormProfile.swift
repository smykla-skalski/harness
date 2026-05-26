import Foundation

/// Per-platform composer behavior for `CommandFormModel`. Mirrors the way
/// `MirrorStoreProfile` carries the store's platform differences, but for the
/// command form: the iPhone and watch composers diverge on command expiry, the
/// merge audit reason they seed, the default label, whether the dry-run payload
/// key is sent, whether prompt presets are resolved, and whether the merge audit
/// reason is pre-seeded. Display copy (confirmation wording) stays in each view.
public struct CommandFormProfile: Sendable {
  public let commandExpiry: TimeInterval
  public let mergeAuditReason: String
  public let defaultLabel: String
  public let includesDryRun: Bool
  public let resolvesPromptPresets: Bool
  public let seedsMergeAuditReason: Bool

  public init(
    commandExpiry: TimeInterval,
    mergeAuditReason: String,
    defaultLabel: String,
    includesDryRun: Bool,
    resolvesPromptPresets: Bool,
    seedsMergeAuditReason: Bool
  ) {
    self.commandExpiry = commandExpiry
    self.mergeAuditReason = mergeAuditReason
    self.defaultLabel = defaultLabel
    self.includesDryRun = includesDryRun
    self.resolvesPromptPresets = resolvesPromptPresets
    self.seedsMergeAuditReason = seedsMergeAuditReason
  }

  /// iPhone: 15 minute expiry, dry-run toggle shown, raw prompt, audit reason
  /// typed by the user (not pre-seeded), no default label.
  public static let phone = CommandFormProfile(
    commandExpiry: 15 * 60,
    mergeAuditReason: "Confirmed from iPhone.",
    defaultLabel: "",
    includesDryRun: true,
    resolvesPromptPresets: false,
    seedsMergeAuditReason: false
  )

  /// Watch: 10 minute expiry, no dry-run, prompt presets resolved to text, the
  /// merge audit reason pre-seeded, and a default label for quick labelling.
  public static let watch = CommandFormProfile(
    commandExpiry: 10 * 60,
    mergeAuditReason: "Confirmed from Apple Watch.",
    defaultLabel: "harness:needs-human",
    includesDryRun: false,
    resolvesPromptPresets: true,
    seedsMergeAuditReason: true
  )
}
