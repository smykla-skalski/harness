import Testing

@testable import HarnessMonitorUIPreviewable

/// Cmd+S routes through `PolicyCanvasSaveFocus` published from the canvas to the
/// app's File menu. These pin the dispatcher invocation and the focus equality
/// the scene-value diffing relies on.
@Suite("Policy canvas save focus")
@MainActor
struct PolicyCanvasSaveFocusTests {
  @Test("performSave invokes the bound closure")
  func performSaveInvokesBoundClosure() {
    let dispatcher = PolicyCanvasSaveFocusDispatcher()
    var calls = 0
    dispatcher.save = { calls += 1 }

    dispatcher.performSave()

    #expect(calls == 1)
  }

  @Test("performSave is a no-op when no closure is bound")
  func performSaveNoopWhenUnbound() {
    let dispatcher = PolicyCanvasSaveFocusDispatcher()
    // Must not trap when the host never bound a save action.
    dispatcher.performSave()
  }

  @Test("focus equality keys on canSave and dispatcher identity")
  func focusEqualityKeysOnStateAndIdentity() {
    let dispatcher = PolicyCanvasSaveFocusDispatcher()
    let enabled = PolicyCanvasSaveFocus(canSave: true, dispatcher: dispatcher)
    let enabledAgain = PolicyCanvasSaveFocus(canSave: true, dispatcher: dispatcher)
    let disabled = PolicyCanvasSaveFocus(canSave: false, dispatcher: dispatcher)
    let otherDispatcher = PolicyCanvasSaveFocus(
      canSave: true,
      dispatcher: PolicyCanvasSaveFocusDispatcher()
    )

    #expect(enabled == enabledAgain)
    #expect(enabled != disabled)
    #expect(enabled != otherDispatcher)
  }
}
