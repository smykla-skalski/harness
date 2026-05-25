import Foundation
import Testing

/// Source contract for plumbing rich threads + visibility + resolve/reply ports
/// from the Reviews Files panes into the diff canvas through the environment.
/// The closures are store-bound (not unit testable in isolation); live behavior
/// is covered by the Phase 8 launch verification.
@Suite("Dashboard review inline conversation plumbing contracts")
struct InlineConversationPlumbingTests {
  @Test("the diff grid pulls the conversation context from the environment")
  func gridReadsConversationFromEnvironment() throws {
    let grid = try source(named: "Views/Dashboard/DashboardReviewFileDiffGrid.swift")
    #expect(grid.contains("@Environment(\\.reviewInlineConversationContext)"))
    #expect(grid.contains("conversationThreads: conversation?.threads ?? []"))
    #expect(grid.contains("conversationVisibility: conversation?.visibility ?? .all"))
    #expect(grid.contains("onResolveToggle: conversation?.onResolveToggle"))
  }

  @Test("the Files detail pane builds a context from full threads + store ports")
  func detailPaneBuildsContext() throws {
    let pane = try source(named: "Views/Dashboard/DashboardReviewFilesModeDetailPane.swift")
    // Rich threads, not just anchors, feed the cards via the environment.
    #expect(pane.contains("threadIndex.threads(forPath: file.path)"))
    #expect(pane.contains("\\.reviewInlineConversationContext"))
    #expect(pane.contains("preferences.snapshot.filesConversationVisibility"))

    // The context builder (resolve + reply + avatar via the store) lives in the
    // pane's conversation companion after the Phase 7 toggle split.
    let conversation = try source(
      named: "Views/Dashboard/DashboardReviewFilesModeDetailPane+Conversation.swift"
    )
    #expect(conversation.contains("store.setReviewThreadResolved("))
    #expect(conversation.contains("store.postReviewFileComment("))
    #expect(conversation.contains("store.reviewAvatarImage("))
    #expect(conversation.contains(".reply(file: file, thread: thread.anchor)"))
  }

  @Test("the inline Files section also feeds a per-file context")
  func filesSectionBuildsContext() throws {
    let section = try source(named: "Views/Dashboard/DashboardReviewFilesSection.swift")
    #expect(section.contains("\\.reviewInlineConversationContext"))
    #expect(section.contains("threadIndex.threads(forPath: file.path)"))
    #expect(section.contains("store.setReviewThreadResolved("))
    #expect(section.contains("store.postReviewFileComment("))
  }

  @Test("the conversation context is an environment value")
  func contextIsEnvironmentValue() throws {
    let context = try source(
      named: "Views/Dashboard/DashboardReviewInlineConversationContext.swift"
    )
    #expect(context.contains("struct DashboardReviewInlineConversationContext"))
    #expect(context.contains("var onResolveToggle: (String, Bool) async -> Void"))
    #expect(context.contains("var onReply: (String, String) async -> Bool"))
    #expect(context.contains("@Entry var reviewInlineConversationContext"))
  }

  private func source(named relativePath: String) throws -> String {
    try String(contentsOf: previewableSourceURL(named: relativePath), encoding: .utf8)
  }

  private func previewableSourceURL(named relativePath: String) -> URL {
    repoRoot()
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(relativePath)
  }

  private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
