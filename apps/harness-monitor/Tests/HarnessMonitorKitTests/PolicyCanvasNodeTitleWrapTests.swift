import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas node title wrap")
struct PolicyCanvasNodeTitleWrapTests {
  @Test("Inserts zero-width space after every colon")
  func insertsBreakAfterColon() {
    let wrapped = PolicyCanvasNodeTitleWrap.wrapSafe("supervisor:merge-deny")
    #expect(wrapped == "supervisor:\u{200B}merge-deny")
  }

  @Test("Inserts zero-width space after every underscore")
  func insertsBreakAfterUnderscore() {
    let wrapped = PolicyCanvasNodeTitleWrap.wrapSafe("dry_run")
    #expect(wrapped == "dry_\u{200B}run")
  }

  @Test("Inserts breaks at every colon and underscore in identifier")
  func insertsBreaksAtEveryBoundary() {
    let wrapped = PolicyCanvasNodeTitleWrap.wrapSafe("dry_run:mutate_repo")
    #expect(wrapped == "dry_\u{200B}run:\u{200B}mutate_\u{200B}repo")
  }

  @Test("Leaves contiguous letter runs untouched")
  func leavesLetterRunsUnchanged() {
    let wrapped = PolicyCanvasNodeTitleWrap.wrapSafe("evidence pass")
    #expect(wrapped == "evidence pass")
  }

  @Test("Fast path returns input when no break opportunities exist")
  func fastPathForPlainText() {
    let raw = "Merge evidence"
    let wrapped = PolicyCanvasNodeTitleWrap.wrapSafe(raw)
    #expect(wrapped == raw)
  }

  @Test("Is idempotent: running twice produces the same output")
  func idempotent() {
    let once = PolicyCanvasNodeTitleWrap.wrapSafe("human:missing-merge-evidence")
    let twice = PolicyCanvasNodeTitleWrap.wrapSafe(once)
    #expect(once == twice)
  }
}
