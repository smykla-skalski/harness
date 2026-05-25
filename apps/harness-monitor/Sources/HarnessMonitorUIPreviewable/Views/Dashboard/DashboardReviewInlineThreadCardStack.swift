import HarnessMonitorKit
import SwiftUI

/// SwiftUI root hosted in the diff canvas gap below a commented line. Stacks
/// every visible ``DashboardReviewInlineThreadCard`` anchored to one diff row
/// and reports its laid-out height back so the AppKit canvas can size the gap.
///
/// Per-card collapse changes the stack height; `onGeometryChange` feeds the new
/// height to the host, which re-measures and repositions following rows. Each
/// card is keyed `.id(thread.id)` so a recycled host slot re-seeds collapse
/// state per thread instead of inheriting the previous thread's.
struct DashboardReviewInlineThreadCardStack: View {
  let threads: [DashboardReviewFileThread]
  let viewerLogin: String?
  let fontScale: CGFloat
  let leadingInset: CGFloat
  let loadAvatar: TimelineAvatarImageLoader?
  let onResolveToggle: (String, Bool) async -> Void
  let onReply: (String, String) async -> Bool
  let onHeightChange: (CGFloat) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(threads) { thread in
        DashboardReviewInlineThreadCard(
          model: DashboardReviewInlineThreadCardModel(thread: thread),
          viewerLogin: viewerLogin,
          fontScale: fontScale,
          loadAvatar: loadAvatar,
          onResolveToggle: { await onResolveToggle(thread.id, $0) },
          onReply: { await onReply(thread.id, $0) }
        )
        .id(thread.id)
      }
    }
    .padding(.leading, leadingInset)
    .padding(.trailing, 12)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.height
    } action: { height in
      onHeightChange(height)
    }
    .accessibilityIdentifier("dashboardReviewInlineThreadCardStack")
  }
}
