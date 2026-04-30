import HarnessMonitorKit
import SwiftUI

struct SessionTimelineBadge: View {
  enum Style {
    case quiet
    case prominent
  }

  let label: String
  let tint: Color
  let style: Style

  var body: some View {
    Text(label)
      .scaledFont(.caption2.weight(.semibold))
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, verticalPadding)
      .frame(minHeight: minimumHeight)
      .background {
        Capsule(style: .continuous)
          .fill(backgroundTint)
      }
      .overlay {
        Capsule(style: .continuous)
          .stroke(tint.opacity(0.26), lineWidth: 1)
      }
      .foregroundStyle(tint)
  }

  private var horizontalPadding: CGFloat {
    switch style {
    case .quiet:
      6
    case .prominent:
      HarnessMonitorTheme.spacingSM
    }
  }

  private var verticalPadding: CGFloat {
    switch style {
    case .quiet:
      2
    case .prominent:
      3
    }
  }

  private var minimumHeight: CGFloat {
    switch style {
    case .quiet:
      20
    case .prominent:
      22
    }
  }

  private var backgroundTint: Color {
    switch style {
    case .quiet:
      tint.opacity(0.12)
    case .prominent:
      tint.opacity(0.22)
    }
  }
}

struct SessionTimelineStatusBadge: Identifiable {
  let label: String
  let tint: Color

  var id: String { label }
}

extension SessionTimelineTone {
  var color: Color {
    switch self {
    case .info:
      HarnessMonitorTheme.accent
    case .success:
      HarnessMonitorTheme.success
    case .warning:
      HarnessMonitorTheme.caution
    case .critical:
      HarnessMonitorTheme.danger
    }
  }

  var badgeLabel: String {
    switch self {
    case .info:
      "INFO"
    case .success:
      "SUCCESS"
    case .warning:
      "WARN"
    case .critical:
      "DANGER"
    }
  }
}

extension DecisionSeverity {
  var color: Color {
    switch self {
    case .info:
      HarnessMonitorTheme.accent
    case .warn:
      HarnessMonitorTheme.caution
    case .needsUser:
      HarnessMonitorTheme.accent
    case .critical:
      HarnessMonitorTheme.danger
    }
  }

  var badgeLabel: String {
    switch self {
    case .info:
      "INFO"
    case .warn:
      "WARN"
    case .needsUser:
      "NEEDS USER"
    case .critical:
      "DANGER"
    }
  }
}
