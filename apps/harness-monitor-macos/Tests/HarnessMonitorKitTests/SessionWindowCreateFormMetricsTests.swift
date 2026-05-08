import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Session window create form metrics")
struct SessionWindowCreateFormMetricsTests {
  @Test("Metrics scale form padding and preserve large submit hit target")
  func metricsScaleFormPaddingAndPreserveLargeHitTarget() {
    let regular = SessionWindowCreateFormMetrics(fontScale: 1.0)
    let large = SessionWindowCreateFormMetrics(fontScale: 1.8)

    #expect(large.formPadding > regular.formPadding)
    #expect(large.promptMinHeight > regular.promptMinHeight)
    #expect(large.submitButtonMinHeight == 44)
  }

  @Test("Metrics clamp extreme font scales")
  func metricsClampExtremeFontScales() {
    #expect(
      SessionWindowCreateFormMetrics(fontScale: 0.1)
        == SessionWindowCreateFormMetrics(fontScale: 0.85)
    )
    #expect(
      SessionWindowCreateFormMetrics(fontScale: 9.0)
        == SessionWindowCreateFormMetrics(fontScale: 1.8)
    )
  }

  @Test("Validation requires a non-empty name")
  func validationRequiresNonEmptyName() {
    let blank = SessionCreateDraft(kind: .agent, title: "   ", sessionID: "session-1")
    let named = SessionCreateDraft(kind: .agent, title: "Review worker", sessionID: "session-1")

    #expect(SessionWindowCreateFormValidation.message(for: blank) == "Agent name is required.")
    #expect(SessionWindowCreateFormValidation.message(for: named) == nil)
  }

  @MainActor
  @Test("Cancelling a create draft clears it and returns to its section")
  func cancellingCreateDraftClearsItAndReturnsToSection() {
    let state = SessionWindowStateCache(sessionID: "session-1")

    state.selectCreate(.decision)
    var draft = SessionCreateDraft(kind: .decision, sessionID: "session-1")
    draft.title = "Review prompt"
    state.updateCreateDraft(draft)
    state.cancelCreateDraft(.decision)

    #expect(!state.sectionState.hasDraft(.decision))
    #expect(state.selection == .route(.decisions))
    #expect(state.navigationHistory.backStack.allSatisfy { $0.createDraft == nil })
    #expect(state.navigationHistory.forwardStack.allSatisfy { $0.createDraft == nil })
  }

  @Test("Create form keeps focus and cancel affordances in source")
  func createFormKeepsFocusAndCancelAffordancesInSource() throws {
    let source = try sourceFile(named: "SessionWindowCreateForm.swift")

    #expect(source.contains("@FocusState"))
    #expect(source.contains("Button(\"Cancel\", role: .cancel)"))
    #expect(source.contains("SessionWindowCreateFormValidation.message"))
  }

  private func sourceFile(named relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent(
        "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/Sessions"
      )
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
