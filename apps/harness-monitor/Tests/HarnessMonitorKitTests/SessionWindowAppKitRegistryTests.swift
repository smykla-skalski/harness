#if canImport(AppKit)
  import AppKit
  import Testing

  import HarnessMonitorUIPreviewable

  @MainActor
  @Suite("Session window AppKit registry")
  struct SessionWindowAppKitRegistryTests {

    @Test
    func waiterResolvesImmediatelyWhenPredicateAlreadyMatches() async {
      let registry = SessionWindowAppKitRegistry()
      let window = makeOffscreenWindow()
      registry.bind(window: window, sessionID: "session-A")

      let resolved = await registry.waitForBindings(
        satisfying: { $0.contains("session-A") },
        timeout: .milliseconds(200)
      )

      #expect(resolved)
      registry.unbind(window: window)
    }

    @Test
    func waiterResolvesOnFirstMatchingBind() async throws {
      let registry = SessionWindowAppKitRegistry()

      let task = Task { @MainActor in
        await registry.waitForBindings(
          satisfying: { $0.contains("session-B") },
          timeout: .milliseconds(500)
        )
      }

      // Yield long enough for the child Task to register the waiter
      // before the bind fires.
      try await Task.sleep(for: .milliseconds(50))

      let window = makeOffscreenWindow()
      registry.bind(window: window, sessionID: "session-B")

      let resolved = await task.value
      #expect(resolved)
      registry.unbind(window: window)
    }

    @Test
    func waiterReturnsFalseAfterTimeoutWhenPredicateNeverMatches() async {
      let registry = SessionWindowAppKitRegistry()

      let resolved = await registry.waitForBindings(
        satisfying: { $0.contains("never-bound") },
        timeout: .milliseconds(80)
      )

      #expect(!resolved)
    }

    @Test
    func windowForSessionIDReturnsBoundWindowAndNilAfterUnbind() {
      let registry = SessionWindowAppKitRegistry()
      let window = makeOffscreenWindow()

      registry.bind(window: window, sessionID: "indexed")
      #expect(registry.window(forSessionID: "indexed") === window)
      #expect(registry.window(forSessionID: "absent") == nil)

      registry.unbind(window: window)
      #expect(registry.window(forSessionID: "indexed") == nil)
    }

    @Test
    func bindReplacingSessionIDReleasesPriorReverseIndexEntry() {
      let registry = SessionWindowAppKitRegistry()
      let window = makeOffscreenWindow()

      registry.bind(window: window, sessionID: "first")
      registry.bind(window: window, sessionID: "second")

      #expect(registry.window(forSessionID: "first") == nil)
      #expect(registry.window(forSessionID: "second") === window)
      registry.unbind(window: window)
    }

    private func makeOffscreenWindow() -> NSWindow {
      NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
        styleMask: .borderless,
        backing: .buffered,
        defer: true
      )
    }
  }
#endif
