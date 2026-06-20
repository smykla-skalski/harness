import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

/// Action button used by `PolicyCanvasTopBar` (Reformat, Make live). Split out
/// of `PolicyCanvasChromeViews.swift` on touch during Wave 4L fix-up so the
/// chrome file lands under the 420-line cap. Defaults to the bordered glass
/// variant; the single primary call-to-action (Make live) passes `.prominent`
/// for the `.glassProminent` treatment.
///
/// While a daemon round-trip is in flight (`isBusy == true`) the leading
/// icon swaps for a small spinner; the title text stays so keyboard
/// navigation and VoiceOver continue to announce the action.
struct PolicyCanvasActionButton: View {
  let title: String
  let systemImage: String
  var variant: HarnessMonitorActionButtonVariant = .bordered
  var tint = PolicyCanvasVisualStyle.activeTint
  var isDisabled = false
  var disabledReason: String?
  var isBusy = false
  let accessibilityIdentifier: String
  let action: @MainActor () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        if isBusy {
          // Replace the leading icon with a small spinner while a daemon
          // round-trip is in flight. The label text stays — keyboard
          // navigation and VoiceOver still announce the action — but the
          // user sees the action is committed and pending.
          HarnessMonitorSpinner(size: 14, tint: PolicyCanvasVisualStyle.secondaryText)
          Text(title)
            .scaledFont(.callout.weight(.semibold))
            .lineLimit(1)
        } else {
          Label(title, systemImage: systemImage)
            .scaledFont(.callout.weight(.semibold))
            .lineLimit(1)
        }
      }
    }
    .accessibilityIdentifier(accessibilityIdentifier)
    .accessibilityLabel(title)
    .harnessActionButtonStyle(
      variant: variant,
      tint: variant == .prominent ? tint : tint.opacity(0.85)
    )
    .controlSize(.small)
    .disabled(isDisabled || isBusy)
    .help(helpText)
  }

  private var helpText: String {
    if isBusy {
      return "\(title) in progress"
    }
    if isDisabled {
      return disabledReason ?? title
    }
    return title
  }
}
