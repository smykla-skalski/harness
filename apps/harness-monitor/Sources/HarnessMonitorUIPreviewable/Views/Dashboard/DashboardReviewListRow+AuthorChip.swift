import AppKit
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
  let authorAssociation: ReviewAuthorAssociation
  let usesSelectedBackgroundContrast: Bool

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
    .frame(width: avatarSize, height: avatarSize)
    .background {
      if let roleHaloStyle = dashboardReviewAuthorHaloStyle(
        for: authorAssociation,
        usesSelectedBackgroundContrast: usesSelectedBackgroundContrast
      ) {
        Circle()
          .fill(roleHaloStyle.fillColor)
          .padding(-roleHaloStyle.padding)
      }
    }
    .overlay {
      if let roleHaloStyle = dashboardReviewAuthorHaloStyle(
        for: authorAssociation,
        usesSelectedBackgroundContrast: usesSelectedBackgroundContrast
      ) {
        Circle()
          .stroke(
            roleHaloStyle.strokeColor,
            style: StrokeStyle(
              lineWidth: roleHaloStyle.lineWidth,
              dash: roleHaloStyle.dash
            )
          )
          .padding(-roleHaloStyle.padding)
      }
    }
    .help(trimmedLogin.isEmpty ? "Unknown author" : "@\(trimmedLogin)")
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      trimmedLogin.isEmpty ? "Unknown author" : "Author @\(trimmedLogin)"
    )
    .accessibilityValue(authorAssociationAccessibilityLabel)
  }

  private var avatarSize: CGFloat { 16 }

  private var resolvedAvatarURL: URL? {
    avatarURL ?? ReviewAvatarCache.fallbackAvatarURL(login: trimmedLogin)
  }

  private var authorAssociationAccessibilityLabel: String {
    switch authorAssociation {
    case .owner, .member, .collaborator:
      "Core contributor"
    case .contributor, .mannequin:
      "External contributor"
    case .firstTimer, .firstTimeContributor:
      "First-time contributor"
    case .none, .other:
      ""
    }
  }
}

struct DashboardReviewAuthorHaloStyle {
  let strokeColor: Color
  let fillColor: Color
  let lineWidth: CGFloat
  let dash: [CGFloat]
  let padding: CGFloat
}

func dashboardReviewAuthorHaloStyle(
  for authorAssociation: ReviewAuthorAssociation,
  usesSelectedBackgroundContrast: Bool
) -> DashboardReviewAuthorHaloStyle? {
  let selectedForeground = Color(nsColor: .alternateSelectedControlTextColor)
  switch authorAssociation {
  case .owner, .member, .collaborator:
    return DashboardReviewAuthorHaloStyle(
      strokeColor: usesSelectedBackgroundContrast
        ? selectedForeground.opacity(0.96)
        : HarnessMonitorTheme.accent.opacity(0.78),
      fillColor: usesSelectedBackgroundContrast
        ? selectedForeground.opacity(0.16)
        : HarnessMonitorTheme.accent.opacity(0.12),
      lineWidth: 1.25,
      dash: [],
      padding: 5
    )
  case .contributor, .mannequin:
    return DashboardReviewAuthorHaloStyle(
      strokeColor: usesSelectedBackgroundContrast
        ? selectedForeground.opacity(0.72)
        : HarnessMonitorTheme.tertiaryInk.opacity(0.42),
      fillColor: usesSelectedBackgroundContrast
        ? selectedForeground.opacity(0.08)
        : HarnessMonitorTheme.secondaryInk.opacity(0.06),
      lineWidth: 1,
      dash: [],
      padding: 5
    )
  case .firstTimer, .firstTimeContributor:
    return DashboardReviewAuthorHaloStyle(
      strokeColor: usesSelectedBackgroundContrast
        ? selectedForeground.opacity(0.96)
        : HarnessMonitorTheme.success.opacity(0.82),
      fillColor: usesSelectedBackgroundContrast
        ? selectedForeground.opacity(0.16)
        : HarnessMonitorTheme.success.opacity(0.12),
      lineWidth: 1.25,
      dash: [2, 2],
      padding: 5
    )
  case .none, .other:
    return nil
  }
}
