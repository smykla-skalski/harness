import HarnessMonitorKit
import SwiftUI

struct DashboardReviewMetricPill: View {
  let title: String
  let value: Int
  let tint: Color
  let help: String?

  init(title: String, value: Int, tint: Color, help: String? = nil) {
    self.title = title
    self.value = value
    self.tint = tint
    self.help = help
  }

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      Text(title)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text(verbatim: String(value))
        .foregroundStyle(tint)
    }
    .scaledFont(.caption.weight(.semibold))
    .lineLimit(1)
    .padding(.horizontal, 8)
    .harnessOpticallyBalancedVerticalPadding(4)
    .background {
      RoundedRectangle(
        cornerRadius: HarnessMonitorTheme.pillCornerRadius,
        style: .continuous
      )
      .fill(tint.opacity(0.14))
    }
    .overlay {
      RoundedRectangle(
        cornerRadius: HarnessMonitorTheme.pillCornerRadius,
        style: .continuous
      )
      .strokeBorder(tint.opacity(0.34), lineWidth: 1)
    }
    .help(expandedHelp)
  }

  /// Expanded summary surfaced via `.help` so abbreviated metric labels
  /// like "Ready" or "Blocked" read in full to screen readers and tooltip
  /// surfaces. Falls back to the explicit `help` override when supplied.
  private var expandedHelp: String {
    if let help, !help.isEmpty {
      return help
    }
    return "\(title): \(value)"
  }
}

struct DashboardReviewStatusPill: View {
  let label: String
  let tint: Color
  var systemImage: String?
  /// Defaults to `true` per the convention documented at the top of this
  /// file. Callers that want the louder weight (the one primary pill per
  /// row's status line) must pass `isQuiet: false` explicitly.
  var isQuiet = true
  var usesSelectedBackgroundContrast = false
  let help: String?

  init(
    label: String,
    tint: Color,
    systemImage: String? = nil,
    isQuiet: Bool = true,
    usesSelectedBackgroundContrast: Bool = false,
    help: String? = nil
  ) {
    self.label = label
    self.tint = tint
    self.systemImage = systemImage
    self.isQuiet = isQuiet
    self.usesSelectedBackgroundContrast = usesSelectedBackgroundContrast
    self.help = help
  }

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      if let systemImage {
        Image(systemName: systemImage)
          .imageScale(.small)
      }
      Text(label)
    }
    .scaledFont(.caption.weight(.semibold))
    .lineLimit(1)
    .padding(.horizontal, 7)
    .harnessOpticallyBalancedVerticalPadding(3)
    .background {
      RoundedRectangle(
        cornerRadius: HarnessMonitorTheme.pillCornerRadius,
        style: .continuous
      )
      .fill(effectiveFillColor)
    }
    .overlay {
      RoundedRectangle(
        cornerRadius: HarnessMonitorTheme.pillCornerRadius,
        style: .continuous
      )
      .strokeBorder(effectiveStrokeColor, lineWidth: 1)
    }
    .foregroundStyle(effectiveForegroundColor)
    .help(help ?? label)
  }

  private var effectiveForegroundColor: Color {
    if usesSelectedBackgroundContrast {
      Color(nsColor: .alternateSelectedControlTextColor)
    } else {
      tint
    }
  }

  private var effectiveFillColor: Color {
    if usesSelectedBackgroundContrast {
      effectiveForegroundColor.opacity(isQuiet ? 0.14 : 0.18)
    } else {
      tint.opacity(isQuiet ? 0.10 : 0.18)
    }
  }

  private var effectiveStrokeColor: Color {
    if usesSelectedBackgroundContrast {
      effectiveForegroundColor.opacity(isQuiet ? 0.32 : 0.42)
    } else {
      tint.opacity(isQuiet ? 0.22 : 0.38)
    }
  }
}

/// Pill that summarises lines-added vs lines-removed for a pull request.
///
/// Two visual modes:
/// - `style == .verbose` (default): the detail-strip `"+N -M"` pill used by
///   `DashboardReviewStatusStrip`.
/// - `style == .compact`: a tighter `"+N -M"` pill the row uses next to the
///   refresh spinner so the change size fits the single-line title row.
struct DashboardReviewChangePill: View {
  enum Style {
    case verbose
    case compact
  }

  let additions: UInt64
  let deletions: UInt64
  let style: Style
  let usesSelectedBackgroundContrast: Bool

  init(
    additions: UInt64,
    deletions: UInt64,
    style: Style = .verbose,
    usesSelectedBackgroundContrast: Bool = false
  ) {
    self.additions = additions
    self.deletions = deletions
    self.style = style
    self.usesSelectedBackgroundContrast = usesSelectedBackgroundContrast
  }

  var body: some View {
    HStack(
      spacing: style == .compact ? HarnessMonitorTheme.spacingXS : HarnessMonitorTheme.spacingSM
    ) {
      Text(verbatim: "+\(additions)")
        .foregroundStyle(additionsForegroundColor)
        .fixedSize(horizontal: true, vertical: false)
      Text(verbatim: "-\(deletions)")
        .foregroundStyle(deletionsForegroundColor)
        .fixedSize(horizontal: true, vertical: false)
    }
    .scaledFont(.caption.weight(.semibold).monospacedDigit())
    .lineLimit(1)
    .fixedSize(horizontal: true, vertical: false)
    .padding(.horizontal, 7)
    .harnessOpticallyBalancedVerticalPadding(3)
    .background {
      RoundedRectangle(
        cornerRadius: HarnessMonitorTheme.pillCornerRadius,
        style: .continuous
      )
      .fill(changeFillColor)
    }
    .overlay {
      RoundedRectangle(
        cornerRadius: HarnessMonitorTheme.pillCornerRadius,
        style: .continuous
      )
      .strokeBorder(changeStrokeColor, lineWidth: 1)
    }
    .accessibilityLabel(accessibilityLabel)
    .help(accessibilityLabel)
  }

  private var additionsForegroundColor: Color {
    if usesSelectedBackgroundContrast {
      changeForegroundColor
    } else {
      HarnessMonitorTheme.success
    }
  }

  private var deletionsForegroundColor: Color {
    if usesSelectedBackgroundContrast {
      changeForegroundColor
    } else {
      HarnessMonitorTheme.danger
    }
  }

  private var changeForegroundColor: Color {
    if usesSelectedBackgroundContrast {
      Color(nsColor: .alternateSelectedControlTextColor)
    } else {
      HarnessMonitorTheme.secondaryInk
    }
  }

  private var changeFillColor: Color {
    if usesSelectedBackgroundContrast {
      changeForegroundColor.opacity(0.14)
    } else {
      HarnessMonitorTheme.secondaryInk.opacity(0.10)
    }
  }

  private var changeStrokeColor: Color {
    if usesSelectedBackgroundContrast {
      changeForegroundColor.opacity(0.32)
    } else {
      HarnessMonitorTheme.secondaryInk.opacity(0.22)
    }
  }

  private var accessibilityLabel: String {
    DashboardReviewInlineChangeStats.accessibilityLabel(
      additions: additions,
      deletions: deletions
    )
  }
}

struct DashboardReviewInlineChangeStats: View {
  let additions: UInt64
  let deletions: UInt64

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Text(verbatim: "+\(additions)")
        .foregroundStyle(HarnessMonitorTheme.success)
      Text(verbatim: "-\(deletions)")
        .foregroundStyle(HarnessMonitorTheme.danger)
    }
    .scaledFont(.caption.weight(.semibold).monospacedDigit())
    .lineLimit(1)
    .fixedSize(horizontal: true, vertical: false)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.accessibilityLabel(additions: additions, deletions: deletions))
    .help(Self.accessibilityLabel(additions: additions, deletions: deletions))
  }

  static func accessibilityLabel(additions: UInt64, deletions: UInt64) -> String {
    "Line changes: \(additions) \(additions == 1 ? "addition" : "additions"), "
      + "\(deletions) \(deletions == 1 ? "deletion" : "deletions")"
  }
}
