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
