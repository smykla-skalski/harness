import HarnessMonitorKit
import SwiftUI

/// Compact author avatar rendered to the left of the title in the Reviews
/// route list row.
///
/// The avatar is fetched through `HarnessMonitorStore.reviewAvatarImage` so
/// it shares the SwiftData-backed `ReviewAvatarCache` with the conversation
/// timeline. Prefer the daemon-provided `authorAvatarURL`; older payloads
/// can still fall back to the login-derived URL when the explicit avatar is
/// absent.
///
/// Visual contract is *avatar only* — the previous `@login` text node was
/// almost always truncated in the narrow Reviews pane and read as noise
/// next to the title. The handle is still recoverable on hover via
/// `.help(...)` and via VoiceOver via `accessibilityLabel`, but it never
/// occupies horizontal space the title row needs.
struct DashboardReviewListRowAuthorChip: View {
  let login: String
  let avatarURL: URL?

  @Environment(HarnessMonitorStore.self)
  private var store

  private var trimmedLogin: String {
    login.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    Group {
      if trimmedLogin.isEmpty {
        // No author info at all: render a neutral placeholder so the row
        // still claims the same horizontal space (keeps row geometry stable).
        Circle()
          .fill(Color.secondary.opacity(0.18))
          .frame(width: avatarSize, height: avatarSize)
          .accessibilityHidden(true)
      } else {
        AvatarImageView(
          login: trimmedLogin,
          avatarURL: resolvedAvatarURL,
          size: avatarSize,
          loadImage: { login, avatarURL, targetPixel in
            await store.reviewAvatarImage(
              login: login,
              avatarURL: avatarURL,
              targetPixel: targetPixel
            )
          }
        )
      }
    }
    .help(trimmedLogin.isEmpty ? "Unknown author" : "@\(trimmedLogin)")
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      trimmedLogin.isEmpty ? "Unknown author" : "Author @\(trimmedLogin)"
    )
  }

  private var avatarSize: CGFloat { 16 }

  private var resolvedAvatarURL: URL? {
    avatarURL ?? ReviewAvatarCache.fallbackAvatarURL(login: trimmedLogin)
  }
}
