import HarnessMonitorKit
import SwiftUI

public struct HarnessMonitorFeedbackToastView: View {
  public let toast: ToastSlice
  public let position: ActionFeedback.Position
  private let detailsInitiallyExpanded: Bool

  public init(
    toast: ToastSlice,
    position: ActionFeedback.Position = .topTrailing,
    detailsInitiallyExpanded: Bool = false
  ) {
    self.toast = toast
    self.position = position
    self.detailsInitiallyExpanded = detailsInitiallyExpanded
  }

  public var body: some View {
    HarnessMonitorGlassControlGroup(spacing: HarnessMonitorTheme.spacingXS) {
      VStack(alignment: .trailing, spacing: HarnessMonitorTheme.spacingXS) {
        ForEach(visibleFeedback) { feedback in
          HarnessMonitorFeedbackToastRow(
            feedback: feedback,
            toast: toast,
            canUndo: toast.hasUndoAction(id: feedback.id),
            detailsInitiallyExpanded: detailsInitiallyExpanded
          )
        }
      }
    }
    .frame(maxWidth: 540, alignment: .trailing)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.actionToast)
    .accessibilityFrameMarker(HarnessMonitorAccessibility.actionToastFrame)
    .accessibilityTestProbe(
      HarnessMonitorAccessibility.actionToast,
      value: "count=\(visibleFeedback.count) position=\(position.rawValue)"
    )
  }

  private var visibleFeedback: [ActionFeedback] {
    let feedback = toast.activeFeedback(in: position)
    return position == .bottomTrailing ? Array(feedback.reversed()) : feedback
  }
}
