import Foundation

/// Copies every persisted `UserDefaults` key that used to belong to the
/// dashboard "Dependencies" feature onto its renamed "Reviews" counterpart
/// and then deletes the source key. Runs once per defaults store, gated by a
/// completion flag so subsequent launches no-op.
///
/// Three prefix families participate; each old prefix maps to a matching new
/// prefix at the same index:
///
/// - `dashboard.dependencies.<rest>` → `dashboard.reviews.<rest>`
/// - `dependencies.<rest>` → `reviews.<rest>`
/// - `settingsDependencies<rest>` → `settingsReviews<rest>`
///
/// The longer/more-specific prefixes appear first so the `hasPrefix` scan
/// does not over-match (`dashboard.dependencies.` must be detected before the
/// bare `dependencies.` family).
public enum HarnessMonitorReviewsUserDefaultsMigration {
  /// `UserDefaults` key that records a successful migration so this helper
  /// is idempotent across relaunches.
  public static let completedFlagKey = "reviewsUserDefaultsMigrationCompleted"

  /// Old key prefixes in match-priority order (longest-first).
  static let oldKeyPrefixes: [String] = [
    "dashboard.dependencies.",
    "dependencies.",
    "settingsDependencies",
  ]

  /// New key prefixes mapped 1:1 to `oldKeyPrefixes`.
  static let newKeyPrefixes: [String] = [
    "dashboard.reviews.",
    "reviews.",
    "settingsReviews",
  ]

  /// Copies every old `dashboard.dependencies.*` / `dependencies.*` /
  /// `settingsDependencies*` key onto its renamed `dashboard.reviews.*` /
  /// `reviews.*` / `settingsReviews*` counterpart and deletes the source.
  /// Marks `completedFlagKey` on success so reentries no-op.
  public static func runIfNeeded(defaults: UserDefaults = .standard) {
    guard !defaults.bool(forKey: completedFlagKey) else { return }
    migrate(defaults: defaults)
    defaults.set(true, forKey: completedFlagKey)
  }

  /// Internal entry point used by tests to exercise the copy step
  /// independent of the gating flag. Production callers should use
  /// `runIfNeeded(defaults:)` so the migration runs at most once.
  static func migrate(defaults: UserDefaults) {
    let snapshot = defaults.dictionaryRepresentation().keys
    for oldKey in snapshot {
      guard let mapping = matchingPrefix(for: oldKey) else { continue }
      let suffix = oldKey.dropFirst(mapping.old.count)
      let newKey = mapping.new + suffix
      if let value = defaults.object(forKey: oldKey) {
        defaults.set(value, forKey: newKey)
      }
      defaults.removeObject(forKey: oldKey)
    }
  }

  private static func matchingPrefix(for key: String) -> (old: String, new: String)? {
    for index in oldKeyPrefixes.indices {
      let oldPrefix = oldKeyPrefixes[index]
      if key.hasPrefix(oldPrefix) {
        return (oldPrefix, newKeyPrefixes[index])
      }
    }
    return nil
  }
}
