import Foundation

/// Declarative entry into the Open Anything corpus from outside the built-in
/// domain set. A plugin contributes a list of `OpenAnythingRecord` values
/// that the corpus builder appends to the standard records.
///
/// Today no production code registers a plugin; the registry exists so a
/// future feature (e.g. a third-party integration, a debug command tray, a
/// per-tenant action set) can fan records into the palette without touching
/// the corpus builder. Tests can also use it to assert how the corpus mixes
/// custom records with the built-in ones.
public protocol OpenAnythingPlugin: Sendable {
  /// Stable identifier used to dedupe plugins when registering twice and to
  /// drive log diagnostics.
  var id: String { get }

  /// Records the plugin contributes to the current corpus. Called every time
  /// the corpus rebuilds so plugins are free to vary their output by store
  /// state, environment, or time of day.
  func records(input: OpenAnythingCorpusInput) -> [OpenAnythingRecord]
}

/// Process-wide registry of Open Anything plugins. Thread-safe via an
/// internal lock so registration from a background thread cannot race with
/// a corpus rebuild on the main actor.
public final class OpenAnythingPluginRegistry: @unchecked Sendable {
  public static let shared = OpenAnythingPluginRegistry()

  private let lock = NSLock()
  private var plugins: [String: any OpenAnythingPlugin] = [:]

  public init() {}

  /// Register (or replace) a plugin keyed by its id.
  public func register(_ plugin: any OpenAnythingPlugin) {
    lock.lock()
    defer { lock.unlock() }
    plugins[plugin.id] = plugin
  }

  /// Unregister by id. No-op if not registered.
  public func unregister(id: String) {
    lock.lock()
    defer { lock.unlock() }
    plugins.removeValue(forKey: id)
  }

  /// Snapshot of registered plugins for a corpus build. The order is the
  /// alphabetical id order so the corpus output stays deterministic across
  /// builds.
  public func snapshot() -> [any OpenAnythingPlugin] {
    lock.lock()
    defer { lock.unlock() }
    return plugins.keys.sorted().compactMap { plugins[$0] }
  }

  /// Records contributed by all registered plugins, flattened in registry
  /// order. Returns an empty array when no plugins are registered.
  public func records(input: OpenAnythingCorpusInput) -> [OpenAnythingRecord] {
    snapshot().flatMap { $0.records(input: input) }
  }

  /// Clear all plugins. Intended for tests.
  public func reset() {
    lock.lock()
    defer { lock.unlock() }
    plugins.removeAll()
  }
}
