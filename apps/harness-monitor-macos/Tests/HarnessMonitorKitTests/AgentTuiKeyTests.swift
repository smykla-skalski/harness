import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("AgentTuiKey")
struct AgentTuiKeyTests {
  @Test("keyboard glyphs use platform key symbols")
  func keyboardGlyphsUsePlatformKeySymbols() {
    #expect(AgentTuiKey.enter.glyph == "↩")
    #expect(AgentTuiKey.tab.glyph == "⇥")
    #expect(AgentTuiKey.escape.glyph == "⎋")
    #expect(AgentTuiKey.backspace.glyph == "⌫")
    #expect(AgentTuiKey.arrowUp.glyph == "↑")
    #expect(AgentTuiKey.arrowDown.glyph == "↓")
    #expect(AgentTuiKey.arrowLeft.glyph == "←")
    #expect(AgentTuiKey.arrowRight.glyph == "→")
  }

  @MainActor
  @Test("key sequence buffer resets idle timer and flushes one timed request")
  func keySequenceBufferFlushesTimedRequestAfterIdleWindow() async throws {
    let clock = TestKeySequenceClock()
    let buffer = AgentTuiWindowView.KeySequenceBuffer(clock: clock)
    let recorder = FlushRecorder()

    buffer.enqueue(input: .key(.enter), glyph: "↩", tuiID: "tui-1") { tuiID, request in
      await recorder.record(tuiID: tuiID, request: request)
    }

    clock.advance(by: .milliseconds(200))
    await drainTasks()
    #expect(await recorder.snapshot().isEmpty)

    buffer.enqueue(input: .control("c"), glyph: "⌃C", tuiID: "tui-1") { tuiID, request in
      await recorder.record(tuiID: tuiID, request: request)
    }
    #expect(buffer.pendingHint == "↩⌃C")

    clock.advance(by: .milliseconds(200))
    await drainTasks()
    #expect(await recorder.snapshot().isEmpty)

    clock.advance(by: .milliseconds(150))
    await drainTasks()

    let flushed = await recorder.snapshot()
    #expect(flushed.count == 1)
    #expect(flushed.first?.tuiID == "tui-1")
    #expect(
      flushed.first?.request.sequence?.steps.map(\.delayBeforeMs)
        == [0, 200]
    )
    #expect(buffer.pendingHint == nil)
    #expect(buffer.pendingTuiID == nil)
  }

  @MainActor
  @Test("forced flush preserves the original TUI target")
  func forcedFlushPreservesOriginalTarget() async throws {
    let clock = TestKeySequenceClock()
    let buffer = AgentTuiWindowView.KeySequenceBuffer(clock: clock)
    let recorder = FlushRecorder()

    buffer.enqueue(input: .key(.tab), glyph: "⇥", tuiID: "tui-original") { tuiID, request in
      await recorder.record(tuiID: tuiID, request: request)
    }

    await buffer.flush()

    let flushed = await recorder.snapshot()
    #expect(flushed.count == 1)
    #expect(flushed.first?.tuiID == "tui-original")
    #expect(flushed.first?.request.sequence?.steps.map(\.input) == [.key(.tab)])
    #expect(buffer.pendingHint == nil)
  }

  @MainActor
  @Test("dropping a queued key sequence clears the hint and cancels idle flush")
  func droppingQueuedKeySequenceClearsState() async throws {
    let clock = TestKeySequenceClock()
    let buffer = AgentTuiWindowView.KeySequenceBuffer(clock: clock)
    let recorder = FlushRecorder()

    buffer.enqueue(input: .key(.escape), glyph: "⎋", tuiID: "tui-drop") { tuiID, request in
      await recorder.record(tuiID: tuiID, request: request)
    }
    #expect(buffer.pendingHint == "⎋")

    buffer.drop()
    clock.advance(by: .seconds(1))
    await drainTasks()

    #expect(await recorder.snapshot().isEmpty)
    #expect(buffer.pendingHint == nil)
    #expect(buffer.pendingTuiID == nil)
  }
}

private actor FlushRecorder {
  struct Entry: Equatable {
    let tuiID: String
    let request: AgentTuiInputRequest
  }

  private var entries: [Entry] = []

  func record(tuiID: String, request: AgentTuiInputRequest) {
    entries.append(Entry(tuiID: tuiID, request: request))
  }

  func snapshot() -> [Entry] {
    entries
  }
}

@MainActor
private func drainTasks() async {
  for _ in 0..<10 {
    await Task.yield()
  }
}

@MainActor
private final class TestKeySequenceClock: AgentTuiWindowView.KeySequenceClock {
  private var current = ContinuousClock.now

  var now: ContinuousClock.Instant {
    current
  }

  func sleep(until deadline: ContinuousClock.Instant) async throws {
    while current < deadline {
      try Task.checkCancellation()
      await Task.yield()
    }
  }

  func advance(by duration: Duration) {
    current = current.advanced(by: duration)
  }
}
