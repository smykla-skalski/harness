import Foundation
import HarnessMonitorKit

struct DashboardReviewActivityInlineConversation: Equatable, Sendable {
  let thread: DashboardReviewFileThread
  let quotedDiffContext: DashboardReviewActivityQuotedDiffContext?
  let isTruncated: Bool
}

struct DashboardReviewActivityQuotedDiffContext: Equatable, Sendable {
  let path: String
  let locationLabel: String
  let lines: [DashboardReviewActivityQuotedDiffLine]
}

struct DashboardReviewActivityQuotedDiffLine: Identifiable, Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case addition
    case deletion
    case context
    case overflow
  }

  let id: Int
  let kind: Kind
  let prefix: String
  let text: String
}

enum DashboardReviewActivityInlineConversationBuilder {
  private static let maxVisibleDiffLines = 6

  private struct QuotedDiffAnchor {
    let line: Int32?
    let originalLine: Int32?
    let side: String?
  }

  static func build(
    from payload: ReviewThreadPayload,
    forceCollapsed: Bool = false
  ) -> DashboardReviewActivityInlineConversation? {
    guard let thread = DashboardReviewFileThread.timelineThread(from: payload) else { return nil }
    let collapsedThread = thread.updatingCollapsed(to: forceCollapsed || thread.isCollapsed)
    return DashboardReviewActivityInlineConversation(
      thread: collapsedThread,
      quotedDiffContext: quotedDiffContext(
        path: payload.path,
        anchor: QuotedDiffAnchor(
          line: payload.line,
          originalLine: payload.originalLine,
          side: payload.diffSide
        ),
        diffHunk: payload.diffHunk,
        outdated: payload.outdated
      ),
      isTruncated: payload.commentsTruncated
    )
  }

  static func build(
    fromInlineCommentGroup comments: [ReviewInlineCommentPayload],
    forceCollapsed: Bool = false
  ) -> DashboardReviewActivityInlineConversation? {
    guard
      let first = comments.min(by: inlineCommentSortPredicate),
      let thread = DashboardReviewFileThread.timelineThread(
        fromInlineCommentGroup: comments,
        isCollapsed: forceCollapsed
      )
    else {
      return nil
    }
    return DashboardReviewActivityInlineConversation(
      thread: thread,
      quotedDiffContext: quotedDiffContext(
        path: first.path,
        anchor: QuotedDiffAnchor(
          line: first.line,
          originalLine: first.originalLine,
          side: nil
        ),
        diffHunk: first.diffHunk,
        outdated: first.outdated
      ),
      isTruncated: false
    )
  }

  private static func quotedDiffContext(
    path: String,
    anchor: QuotedDiffAnchor,
    diffHunk: String?,
    outdated: Bool
  ) -> DashboardReviewActivityQuotedDiffContext? {
    guard !path.isEmpty else { return nil }
    let sideValue = DashboardReviewFileDiffSide(wireValue: anchor.side)
    let anchorLine: Int32?
    switch sideValue {
    case .old:
      anchorLine = anchor.originalLine ?? anchor.line
    case .new:
      anchorLine = anchor.line ?? anchor.originalLine
    case nil:
      anchorLine = anchor.line ?? anchor.originalLine
    }
    let locationLabel: String
    if outdated {
      locationLabel = "Outdated"
    } else if let anchorLine {
      locationLabel = "Line \(anchorLine)"
    } else {
      locationLabel = "Comment context"
    }
    let lines = quotedDiffLines(from: diffHunk)
    if lines.isEmpty, !outdated {
      return DashboardReviewActivityQuotedDiffContext(
        path: path,
        locationLabel: locationLabel,
        lines: []
      )
    }
    return DashboardReviewActivityQuotedDiffContext(
      path: path,
      locationLabel: locationLabel,
      lines: lines
    )
  }

  private static func quotedDiffLines(from diffHunk: String?)
    -> [DashboardReviewActivityQuotedDiffLine]
  {
    guard let diffHunk else { return [] }
    let rawLines = diffHunk.split(
      omittingEmptySubsequences: false,
      whereSeparator: \.isNewline
    ).map(String.init)
    guard !rawLines.isEmpty else { return [] }
    let contentLines =
      rawLines.first?.hasPrefix("@@") == true ? Array(rawLines.dropFirst()) : rawLines
    guard !contentLines.isEmpty else { return [] }

    var lines: [DashboardReviewActivityQuotedDiffLine] = []
    lines.reserveCapacity(min(contentLines.count, maxVisibleDiffLines + 1))
    for (index, line) in contentLines.prefix(maxVisibleDiffLines).enumerated() {
      lines.append(diffLine(from: line, id: index))
    }
    if contentLines.count > maxVisibleDiffLines {
      lines.append(
        DashboardReviewActivityQuotedDiffLine(
          id: lines.count,
          kind: .overflow,
          prefix: "",
          text: "…"
        )
      )
    }
    return lines
  }

  private static func diffLine(
    from rawLine: String,
    id: Int
  ) -> DashboardReviewActivityQuotedDiffLine {
    if rawLine.hasPrefix("+"), !rawLine.hasPrefix("+++") {
      return DashboardReviewActivityQuotedDiffLine(
        id: id,
        kind: .addition,
        prefix: "+",
        text: String(rawLine.dropFirst())
      )
    }
    if rawLine.hasPrefix("-"), !rawLine.hasPrefix("---") {
      return DashboardReviewActivityQuotedDiffLine(
        id: id,
        kind: .deletion,
        prefix: "-",
        text: String(rawLine.dropFirst())
      )
    }
    return DashboardReviewActivityQuotedDiffLine(
      id: id,
      kind: .context,
      prefix: " ",
      text: rawLine.first == " " ? String(rawLine.dropFirst()) : rawLine
    )
  }

  private static func inlineCommentSortPredicate(
    lhs: ReviewInlineCommentPayload,
    rhs: ReviewInlineCommentPayload
  ) -> Bool {
    if lhs.createdAt != rhs.createdAt {
      return lhs.createdAt < rhs.createdAt
    }
    return lhs.id < rhs.id
  }
}
