#if canImport(AppKit)
  import AppKit

  /// Tracks `(NSWindow, sessionID)` bindings for live session windows so the
  /// quit-time path can capture tab grouping and the launch-time path can
  /// re-merge restored windows into their original tab groups. The store's
  /// existing `openSessionWindowsByID` registry uses an opaque SwiftUI-side
  /// `ObjectIdentifier` and never sees the NSWindow, so AppKit-side
  /// operations (reading `tabGroup`, calling `addTabbedWindow`) cannot use
  /// it. This registry fills that gap.
  @MainActor
  public final class SessionWindowAppKitRegistry {
    public static let shared = SessionWindowAppKitRegistry()

    private var bindings: [ObjectIdentifier: Binding] = [:]

    private struct Binding {
      weak var window: NSWindow?
      let sessionID: String
    }

    public init() {}

    public func bind(window: NSWindow, sessionID: String) {
      bindings[ObjectIdentifier(window)] = Binding(window: window, sessionID: sessionID)
    }

    public func unbind(window: NSWindow) {
      bindings.removeValue(forKey: ObjectIdentifier(window))
    }

    /// Live window-to-sessionID pairs. Drops bindings whose window has been
    /// deallocated since they were last bound.
    public func currentBindings() -> [(window: NSWindow, sessionID: String)] {
      var results: [(NSWindow, String)] = []
      var staleKeys: [ObjectIdentifier] = []
      for (key, binding) in bindings {
        if let window = binding.window {
          results.append((window, binding.sessionID))
        } else {
          staleKeys.append(key)
        }
      }
      for key in staleKeys {
        bindings.removeValue(forKey: key)
      }
      return results
    }

    /// Returns the NSWindow currently bound to the given sessionID, if any.
    public func window(forSessionID sessionID: String) -> NSWindow? {
      for (_, binding) in bindings where binding.sessionID == sessionID {
        if let window = binding.window {
          return window
        }
      }
      return nil
    }

    public func resetForTesting() {
      bindings.removeAll()
    }
  }
#endif
