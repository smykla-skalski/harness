import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard review inline thread card model")
struct DashboardReviewInlineThreadCardModelTests {
  @Test("line reference uses the thread anchor line")
  func lineReferenceUsesAnchorLine() {
    let model = DashboardReviewInlineThreadCardModel(thread: thread(line: 42))
    #expect(model.lineReference == "Line 42")
  }

  @Test("line reference falls back to Outdated when the line no longer maps")
  func lineReferenceFallsBackToOutdatedWhenLineMissing() {
    let model = DashboardReviewInlineThreadCardModel(thread: thread(line: nil))
    #expect(model.lineReference == "Outdated")
  }

  @Test("resolve action title toggles with the resolved state")
  func resolveActionTitleTogglesWithState() {
    #expect(DashboardReviewInlineThreadCardModel(thread: thread(isResolved: false))
      .resolveActionTitle == "Resolve")
    #expect(DashboardReviewInlineThreadCardModel(thread: thread(isResolved: true))
      .resolveActionTitle == "Unresolve")
  }

  @Test("resolved chip text shows only while resolved")
  func resolvedChipTextOnlyWhenResolved() {
    #expect(DashboardReviewInlineThreadCardModel(thread: thread(isResolved: false))
      .resolvedChipText == nil)
    #expect(DashboardReviewInlineThreadCardModel(thread: thread(isResolved: true))
      .resolvedChipText == "Resolved")
  }

  @Test("isResolved mirrors the thread state")
  func isResolvedMirrorsThread() {
    #expect(!DashboardReviewInlineThreadCardModel(thread: thread(isResolved: false)).isResolved)
    #expect(DashboardReviewInlineThreadCardModel(thread: thread(isResolved: true)).isResolved)
  }

  @Test("header author prefers the thread starter, then the first comment author")
  func headerAuthorPrefersThreadAuthorThenFirstComment() {
    #expect(DashboardReviewInlineThreadCardModel(thread: thread(authorLogin: "octocat"))
      .headerAuthorLogin == "octocat")
    let fallback = thread(authorLogin: nil, comments: [comment(login: "hubot")])
    #expect(DashboardReviewInlineThreadCardModel(thread: fallback).headerAuthorLogin == "hubot")
  }

  @Test("comment summary pluralizes on the real comment count")
  func commentSummaryPluralizes() {
    let single = thread(comments: [comment(id: "C1")])
    #expect(DashboardReviewInlineThreadCardModel(thread: single).commentSummary == "1 comment")
    let many = thread(comments: [comment(id: "C1"), comment(id: "C2"), comment(id: "C3")])
    #expect(DashboardReviewInlineThreadCardModel(thread: many).commentSummary == "3 comments")
  }

  // MARK: - Fixtures

  private func thread(
    line: Int? = 10,
    isResolved: Bool = false,
    authorLogin: String? = "octocat",
    comments: [DashboardReviewFileThreadComment] = []
  ) -> DashboardReviewFileThread {
    DashboardReviewFileThread(
      id: "T1",
      path: "Sources/App.swift",
      side: .new,
      line: line,
      diffPosition: 3,
      isResolved: isResolved,
      isCollapsed: false,
      authorLogin: authorLogin,
      comments: comments.isEmpty ? [comment()] : comments
    )
  }

  private func comment(
    id: String = "C1",
    login: String? = "octocat",
    body: String = "Looks good to me"
  ) -> DashboardReviewFileThreadComment {
    DashboardReviewFileThreadComment(
      id: id,
      authorLogin: login,
      authorAvatarURL: nil,
      body: body,
      createdAt: "2026-05-25T10:00:00Z",
      url: nil
    )
  }
}
