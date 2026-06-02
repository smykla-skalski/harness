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
  @Environment(\.displayScale)
  private var displayScale

  private var trimmedLogin: String {
    login.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    let roleHaloStyle = dashboardReviewAuthorHaloStyle(
      for: authorAssociation,
      usesSelectedBackgroundContrast: usesSelectedBackgroundContrast
    )

    ZStack {
      if let roleHaloStyle {
        Circle()
          .fill(roleHaloStyle.fillColor)
        Circle()
          .strokeBorder(
            roleHaloStyle.strokeColor,
            style: StrokeStyle(
              lineWidth: roleHaloStyle.lineWidth,
              dash: roleHaloStyle.dash
            )
          )
        avatarContent(size: innerAvatarSize(for: roleHaloStyle))
          .overlay {
            Circle()
              .stroke(Color.white.opacity(0.96), lineWidth: 1)
          }
      } else {
        avatarContent(size: avatarShellSize)
      }
    }
    .frame(width: avatarShellSize, height: avatarShellSize)
    .help(trimmedLogin.isEmpty ? "Unknown author" : "@\(trimmedLogin)")
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      trimmedLogin.isEmpty ? "Unknown author" : "Author @\(trimmedLogin)"
    )
    .accessibilityValue(authorAssociationAccessibilityLabel)
  }

  @ViewBuilder
  private func avatarContent(size: CGFloat) -> some View {
    if trimmedLogin.isEmpty {
      // No author info at all: render a neutral placeholder so the row
      // still claims the same horizontal space (keeps row geometry stable).
      Circle()
        .fill(Color.secondary.opacity(0.18))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    } else {
      AvatarImageView(
        login: trimmedLogin,
        avatarURL: resolvedAvatarURL,
        size: size,
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

  private var avatarShellSize: CGFloat { 16 }
  private var separatorRingWidth: CGFloat { 1 }
  private var devicePixel: CGFloat { 1 / max(displayScale, 1) }

  private func innerAvatarSize(for roleHaloStyle: DashboardReviewAuthorHaloStyle) -> CGFloat {
    max(
      avatarShellSize - (2 * (roleHaloStyle.padding + separatorRingWidth)) - devicePixel,
      1
    )
  }

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
        : HarnessMonitorTheme.success.opacity(0.78),
      fillColor: usesSelectedBackgroundContrast
        ? selectedForeground.opacity(0.16)
        : HarnessMonitorTheme.success.opacity(0.12),
      lineWidth: 3.5,
      dash: [],
      padding: 1.25
    )
  case .contributor, .mannequin:
    return DashboardReviewAuthorHaloStyle(
      strokeColor: usesSelectedBackgroundContrast
        ? selectedForeground.opacity(0.72)
        : HarnessMonitorTheme.tertiaryInk.opacity(0.42),
      fillColor: usesSelectedBackgroundContrast
        ? selectedForeground.opacity(0.08)
        : HarnessMonitorTheme.secondaryInk.opacity(0.06),
      lineWidth: 3,
      dash: [],
      padding: 1.25
    )
  case .firstTimer, .firstTimeContributor:
    return DashboardReviewAuthorHaloStyle(
      strokeColor: usesSelectedBackgroundContrast
        ? selectedForeground.opacity(0.96)
        : HarnessMonitorTheme.success.opacity(0.82),
      fillColor: usesSelectedBackgroundContrast
        ? selectedForeground.opacity(0.16)
        : HarnessMonitorTheme.success.opacity(0.12),
      lineWidth: 3.5,
      dash: [2, 2],
      padding: 1.25
    )
  case .none, .other:
    return nil
  }
}
