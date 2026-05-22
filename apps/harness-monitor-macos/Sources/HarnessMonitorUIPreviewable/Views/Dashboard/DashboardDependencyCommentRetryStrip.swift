import SwiftUI

/// POD error + retry banner for the Dependencies PR comment composer.
/// Takes only the values it needs (message, retry-availability flag,
/// two callbacks) so SwiftUI can skip its body when the inputs don't
/// change — per `references/performance-patterns.md` §3 "Pass Only
/// What Views Need" / §5 "POD Views for Fast Diffing".
///
/// `canRetry` is supplied explicitly (rather than derived inside the
/// strip) because the composer owns the `lastFailedBody`/`isPosting`
/// state that gates retry; passing the derived bool keeps the strip
/// view a pure presentation layer with no @State of its own.
struct DashboardDependencyCommentRetryStrip: View {
  let message: String
  let canRetry: Bool
  let onRetry: () -> Void
  let onDismiss: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Label(message, systemImage: "exclamationmark.triangle")
        .foregroundStyle(.orange)
        .font(.caption)
        .lineLimit(2)
        .accessibilityLabel(Text("Comment failed to send: \(message)"))
      Spacer()
      if canRetry {
        Button("Retry", action: onRetry)
          .harnessActionButtonStyle(variant: .bordered)
          .controlSize(.small)
          .accessibilityLabel(Text("Retry sending previous comment"))
      }
      Button(action: onDismiss) {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.secondary)
      }
      .harnessPlainButtonStyle()
      .accessibilityLabel(Text("Dismiss error"))
    }
    .padding(.vertical, 4)
    .padding(.horizontal, 8)
    .background(.orange.opacity(0.08), in: .rect(cornerRadius: 6))
  }
}
