#if canImport(AppKit)
  import AppKit

  /// Tracks `(NSWindow, sessionID)` bindings for live session windows so the
  /// quit-time path can capture tab grouping and the launch-time path can
  /// re-merge restored windows into their original tab groups. The store's
  /// existing `openSessionWindowsByID` registry uses an opaque SwiftUI-side
  /// `ObjectIdentifier` and never sees the NSWindow, so AppKit-side
  /// operations (reading `tabGroup`, calling `addTabbedWindow`) cannot use
  /// it. This registry fills that gap.
  ///
  /// ## Binding lifetime protocol
  ///
  /// A session window's `(NSWindow, sessionID)` pair is "live" from the
  /// moment `bind(window:sessionID:)` returns until the matching
  /// `unbind(window:)` runs (or until the bound `NSWindow` is deallocated,
  /// at which point the entry is reaped lazily).
  ///
  /// `SessionWindowAppKitBinding` drives bind/unbind through three NSView
  /// hooks; all three are required for net-zero accounting on every SwiftUI
  /// lifecycle path:
  ///
  /// 1. `viewDidMoveToWindow` — fires after the NSView is mounted in its
  ///    host NSWindow. Calls `bind(window:sessionID:)`.
  /// 2. `viewWillMove(toWindow:)` — fires when AppKit detaches the NSView
  ///    (e.g. SwiftUI re-parents the scene). Calls `unbind(window:)` for
  ///    the *previous* window before the move.
  /// 3. `dismantleNSView` — SwiftUI sometimes drops the representable
  ///    without first issuing `viewWillMove(toWindow: nil)` (observed when
  ///    a `WindowGroup` scene is dismissed). The dismantle hook calls
  ///    `removeFromSuperview()` to force the missed move-to-nil transition.
  ///
  /// ## Convergence wait
  ///
  /// Consumers that need to observe binding convergence (e.g. the launch
  /// router waiting for restored windows to bind before merging tabs) call
  /// `waitForBindings(satisfying:timeout:)`. The wait is edge-triggered on
  /// `bind(...)` and falls back to the timeout if the predicate is never
  /// satisfied — never busy-polls.
  @MainActor
  public final class SessionWindowAppKitRegistry {
    public static let shared = SessionWindowAppKitRegistry()

    private struct Binding {
      weak var window: NSWindow?
      let sessionID: String
    }

    private struct Waiter {
      let predicate: (Set<String>) -> Bool
      let continuation: CheckedContinuation<Bool, Never>
    }

    private var bindings: [ObjectIdentifier: Binding] = [:]
    private var sessionIDIndex: [String: ObjectIdentifier] = [:]
    private var waiters: [UUID: Waiter] = [:]

    public init() {}

    public func bind(window: NSWindow, sessionID: String) {
      let key = ObjectIdentifier(window)
      if let prior = bindings[key], prior.sessionID != sessionID,
        sessionIDIndex[prior.sessionID] == key
      {
        sessionIDIndex.removeValue(forKey: prior.sessionID)
      }
      bindings[key] = Binding(window: window, sessionID: sessionID)
      sessionIDIndex[sessionID] = key
      notifyWaiters()
    }

    public func unbind(window: NSWindow) {
      let key = ObjectIdentifier(window)
      guard let binding = bindings.removeValue(forKey: key) else { return }
      if sessionIDIndex[binding.sessionID] == key {
        sessionIDIndex.removeValue(forKey: binding.sessionID)
      }
    }

    /// Live window-to-sessionID pairs. Drops bindings whose window has been
    /// deallocated since they were last bound.
    public func currentBindings() -> [(window: NSWindow, sessionID: String)] {
      reapStaleBindings()
      return bindings.values.compactMap { binding in
        binding.window.map { ($0, binding.sessionID) }
      }
    }

    /// Returns the NSWindow currently bound to the given sessionID, if any.
    /// O(1) via the reverse index.
    public func window(forSessionID sessionID: String) -> NSWindow? {
      guard let key = sessionIDIndex[sessionID],
        let binding = bindings[key],
        let window = binding.window
      else {
        return nil
      }
      return window
    }

    /// Edge-triggered wait. Returns `true` once `predicate(currentSessionIDs)`
    /// is satisfied (re-evaluated on every `bind(...)` call) or `false` after
    /// `timeout` elapses. Replaces the previous launch-router polling: warm
    /// launches finish on the first matching bind; cold launches stay
    /// bounded by the timeout.
    public func waitForBindings(
      satisfying predicate: @escaping @Sendable (Set<String>) -> Bool,
      timeout: Duration
    ) async -> Bool {
      reapStaleBindings()
      if predicate(liveSessionIDs()) { return true }

      let waiterID = UUID()
      return await withCheckedContinuation {
        (continuation: CheckedContinuation<Bool, Never>) in
        waiters[waiterID] = Waiter(
          predicate: predicate,
          continuation: continuation
        )
        Task { @MainActor [weak self] in
          try? await Task.sleep(for: timeout)
          guard let self else { return }
          if let waiter = self.waiters.removeValue(forKey: waiterID) {
            waiter.continuation.resume(returning: false)
          }
        }
      }
    }

    public func resetForTesting() {
      bindings.removeAll()
      sessionIDIndex.removeAll()
      let pending = waiters
      waiters.removeAll()
      for waiter in pending.values {
        waiter.continuation.resume(returning: false)
      }
    }

    private func notifyWaiters() {
      guard !waiters.isEmpty else { return }
      let currentIDs = liveSessionIDs()
      for (id, waiter) in waiters where waiter.predicate(currentIDs) {
        waiters.removeValue(forKey: id)
        waiter.continuation.resume(returning: true)
      }
    }

    private func liveSessionIDs() -> Set<String> {
      var ids: Set<String> = []
      for binding in bindings.values where binding.window != nil {
        ids.insert(binding.sessionID)
      }
      return ids
    }

    private func reapStaleBindings() {
      var staleKeys: [ObjectIdentifier] = []
      for (key, binding) in bindings where binding.window == nil {
        staleKeys.append(key)
      }
      for key in staleKeys {
        if let binding = bindings.removeValue(forKey: key),
          sessionIDIndex[binding.sessionID] == key
        {
          sessionIDIndex.removeValue(forKey: binding.sessionID)
        }
      }
    }
  }
#endif
