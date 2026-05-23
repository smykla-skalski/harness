import Foundation

/// Top-level namespace for the App Intents and Shortcuts surface of Harness
/// Monitor. AppEntity, EntityQuery, and AppIntent types land in follow-up
/// commits; this enum exists so the framework target has at least one
/// public declaration and so callers have a stable namespace to import.
public enum HarnessMonitorIntents {
  /// Module version. Bump on breaking changes to intent class names so
  /// user-built Shortcuts that persisted those identifiers can detect a
  /// schema mismatch and prompt for rebuild.
  public static let moduleVersion = "1.0.0"
}
