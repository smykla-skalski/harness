import Foundation
import WidgetKit

/// Reloads widget timelines after an App Intent mutates the underlying
/// state. Used by the Reviews mutating intents (Approve, Merge,
/// RefreshAll, RefreshRepository) so that a Siri / Spotlight action
/// surfaces the new count on the dock-tile widget and the macOS small
/// widget within a second instead of waiting up to 15 minutes for the
/// next provider tick
///
/// The shared instance routes to `WidgetCenter.shared` in production
/// and to an injected callback in tests, so we can verify which kinds
/// are reloaded without spinning up a real widget host
public actor IntentWidgetReloader {
  public static let shared = IntentWidgetReloader()

  private var override: (@Sendable (String) -> Void)?

  public init() {}

  /// Replaces the production WidgetCenter sink with a test stub.
  /// Pass `nil` to restore production behaviour
  public func setOverrideForTesting(_ block: (@Sendable (String) -> Void)?) {
    self.override = block
  }

  /// Triggers a timeline reload for the given widget kind. Safe to
  /// call from any context - WidgetCenter is `MainActor`-isolated so
  /// the production path hops to the main actor before invoking it
  public func reload(kind: String) async {
    if let override {
      override(kind)
      return
    }
    await MainActor.run {
      WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }
  }

  /// Convenience wrapper for the needs-me count widget. Only reloads
  /// the macOS-host kind; the watchOS complication runs in a separate
  /// process on the paired Apple Watch and is invalidated by the
  /// CloudKit silent-push pipeline, not by `WidgetCenter` calls from
  /// the Mac
  public func reloadNeedsMeCount() async {
    await reload(kind: HarnessMonitorWidgetKinds.needsMeCount)
  }
}
