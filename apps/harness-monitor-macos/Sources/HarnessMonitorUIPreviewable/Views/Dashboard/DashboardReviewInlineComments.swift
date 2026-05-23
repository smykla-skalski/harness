import HarnessMonitorKit
import SwiftUI

struct DashboardReviewFileCommentDraft: Identifiable, Equatable {
  enum Kind: Equatable {
    case newThread
    case reply(threadID: String)
  }

  let id: String
  let kind: Kind
  let path: String
  let line: Int?
  let side: DashboardReviewFileDiffSide?
  let title: String

  static func newThread(
    file: ReviewFile,
    line: Int,
    side: DashboardReviewFileDiffSide
  ) -> Self {
    Self(
      id: "new:\(file.path):\(side.rawValue):\(line)",
      kind: .newThread,
      path: file.path,
      line: line,
      side: side,
      title: "Comment on \(file.path):\(line)"
    )
  }

  static func reply(
    file: ReviewFile,
    thread: DashboardReviewFileThreadAnchor
  ) -> Self {
    Self(
      id: "reply:\(thread.id)",
      kind: .reply(threadID: thread.id),
      path: file.path,
      line: thread.line,
      side: thread.side,
      title: "Reply to thread"
    )
  }
}

struct DashboardReviewInlineCommentSheet: View {
  let draft: DashboardReviewFileCommentDraft
  let viewerLogin: String?
  let onCancel: () -> Void
  let onSend: (String) async -> Void

  @State private var bodyText = ""
  @State private var isSending = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label(draft.title, systemImage: "text.bubble")
          .font(.headline)
        Spacer()
        if let viewerLogin {
          Text("@\(viewerLogin)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      TextField("Write a review comment…", text: $bodyText, axis: .vertical)
        .lineLimit(5...12)
        .textFieldStyle(.roundedBorder)
        .disabled(isSending)
      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
          .disabled(isSending)
        Button("Send") {
          Task {
            isSending = true
            await onSend(bodyText)
            isSending = false
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
      }
    }
    .padding(18)
    .frame(width: 460)
  }
}

struct DashboardReviewFileReviewRail: View {
  let file: ReviewFile
  let threads: [DashboardReviewFileThreadAnchor]
  let onResolve: (String, Bool) -> Void
  let onReply: (DashboardReviewFileThreadAnchor) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Review rail", systemImage: "point.3.connected.trianglepath.dotted")
          .font(.caption.weight(.semibold))
        Spacer()
        Text("\(threads.count) threads")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      if threads.isEmpty {
        Text("No inline threads on this file.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(threads) { thread in
          DashboardReviewFileReviewRailRow(
            thread: thread,
            onResolve: onResolve,
            onReply: onReply
          )
        }
      }
    }
    .padding(10)
    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityIdentifier("dashboardReviewFileReviewRail")
  }
}

private struct DashboardReviewFileReviewRailRow: View {
  let thread: DashboardReviewFileThreadAnchor
  let onResolve: (String, Bool) -> Void
  let onReply: (DashboardReviewFileThreadAnchor) -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: thread.isResolved ? "checkmark.circle" : "text.bubble.fill")
        .foregroundStyle(thread.isResolved ? .green : .orange)
      VStack(alignment: .leading, spacing: 4) {
        Text(thread.preview.isEmpty ? "Review thread" : thread.preview)
          .font(.caption)
          .lineLimit(2)
        HStack(spacing: 8) {
          if let line = thread.line {
            Text("Line \(line)")
          }
          Text("\(thread.commentCount) comments")
          if let author = thread.authorLogin {
            Text("@\(author)")
          }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        HStack(spacing: 8) {
          Button(thread.isResolved ? "Unresolve" : "Resolve") {
            onResolve(thread.id, !thread.isResolved)
          }
          .controlSize(.mini)
          Button("Reply") { onReply(thread) }
            .controlSize(.mini)
        }
      }
      Spacer(minLength: 4)
    }
    .padding(.vertical, 4)
  }
}
