import HarnessMonitorKit
import SwiftUI

@MainActor
private enum FeedbackToastBalancePreviewData {
  static let restartCommand =
    "HARNESS_MONITOR_RUNTIME_LANE='monitor' harness-daemon dev"

  static func makeCompactToast() -> ToastSlice {
    let toast = makeToast()
    toast.presentSuccess("Copied Terminal restart command")
    return toast
  }

  static func makeTitledToast() -> ToastSlice {
    let toast = makeToast()
    toast.presentWarning(
      "Monitor will reconnect after you restart the helper",
      title: "Restart background helper",
      primaryAction: ActionFeedbackAction(
        title: "Copy restart command",
        systemImage: "doc.on.clipboard",
        kind: .copy(text: restartCommand),
        successAnnouncement: "Restart command copied"
      )
    )
    return toast
  }

  static func makeWrappedToast() -> ToastSlice {
    let toast = makeToast()
    toast.presentWarning(
      "Monitor will reconnect to lane \"monitor\" after you restart the helper in"
        + " Terminal",
      title: "Restart background helper"
    )
    return toast
  }

  private static func makeToast() -> ToastSlice {
    let toast = ToastSlice()
    toast.successDismissDelay = .seconds(120)
    toast.warningDismissDelay = .seconds(120)
    toast.failureDismissDelay = .seconds(120)
    toast.undoableDismissDelay = .seconds(120)
    return toast
  }
}

@MainActor
private struct FeedbackToastBalancePreviewSection: View {
  let title: String
  let width: CGFloat
  let toast: ToastSlice

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(title)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)

      HarnessMonitorFeedbackToastView(toast: toast)
        .frame(width: width, alignment: .leading)
    }
  }
}

@MainActor
private struct FeedbackToastBalancePreviewBoard: View {
  let textSizeIndex: Int
  private let compactNarrowToast: ToastSlice
  private let compactWideToast: ToastSlice
  private let titledToast: ToastSlice
  private let wrappedToast: ToastSlice

  init(textSizeIndex: Int = HarnessMonitorTextSize.defaultIndex) {
    self.textSizeIndex = textSizeIndex
    compactNarrowToast = FeedbackToastBalancePreviewData.makeCompactToast()
    compactWideToast = FeedbackToastBalancePreviewData.makeCompactToast()
    titledToast = FeedbackToastBalancePreviewData.makeTitledToast()
    wrappedToast = FeedbackToastBalancePreviewData.makeWrappedToast()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
      FeedbackToastBalancePreviewSection(
        title: "Short single-line @ 360pt",
        width: 360,
        toast: compactNarrowToast
      )

      FeedbackToastBalancePreviewSection(
        title: "Short single-line @ 540pt",
        width: 540,
        toast: compactWideToast
      )

      FeedbackToastBalancePreviewSection(
        title: "Title + action @ 540pt",
        width: 540,
        toast: titledToast
      )

      FeedbackToastBalancePreviewSection(
        title: "Wrapped body @ 540pt",
        width: 540,
        toast: wrappedToast
      )
    }
    .padding(24)
    .frame(width: 620, alignment: .leading)
    .harnessPreviewSceneAppearance(textSizeIndex: textSizeIndex)
  }
}

#Preview("Toast balance board", traits: .fixedLayout(width: 620, height: 660)) {
  FeedbackToastBalancePreviewBoard()
}

#Preview("Toast balance board largest", traits: .fixedLayout(width: 620, height: 860)) {
  FeedbackToastBalancePreviewBoard(textSizeIndex: 6)
}

#Preview("Toast primary action copied", traits: .fixedLayout(width: 360, height: 100)) {
  HarnessMonitorFeedbackToastPrimaryActionButton(
    action: ActionFeedbackAction(
      title: "Copy restart command",
      systemImage: "doc.on.clipboard",
      kind: .copy(text: FeedbackToastBalancePreviewData.restartCommand),
      successAnnouncement: "Restart command copied"
    ),
    copied: true,
    tint: HarnessMonitorTheme.caution,
    reduceMotion: false,
    onPress: {},
    onPendingDismissCancelled: {},
    onBeginDismiss: {},
    onFinishDismiss: {}
  )
  .padding(24)
  .harnessPreviewSceneAppearance()
}
