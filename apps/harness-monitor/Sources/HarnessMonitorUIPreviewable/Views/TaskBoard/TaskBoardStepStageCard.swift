import SwiftUI

/// The focused stage detail: the stage title, what just happened, what Next
/// will do, and a closing slot for whatever controls the stage offers.
/// Arranging that slot is the caller's job; the card only stacks it last.
/// Presentational only - the parent supplies the buttons so this view stores no
/// action closures.
///
/// Carries no surface of its own. It is the detail column of the manual-steps
/// panel, separated from the progress rail by that panel's divider, and a
/// second nested card inside the panel only muddied the hierarchy.
struct TaskBoardStepStageCard<Actions: View>: View {
  let stageTitle: String
  let whatHappened: String?
  let whatNext: String
  private let actions: Actions

  @Environment(\.fontScale)
  private var fontScale

  init(
    stageTitle: String,
    whatHappened: String?,
    whatNext: String,
    @ViewBuilder actions: () -> Actions
  ) {
    self.stageTitle = stageTitle
    self.whatHappened = whatHappened
    self.whatNext = whatNext
    self.actions = actions()
  }

  private var titleFont: Font {
    HarnessMonitorTextSize.scaledFont(.title3.weight(.semibold), by: fontScale)
  }

  var body: some View {
    // Outer spacing is 0 so the Spacer below is the *only* gap above the action
    // slot. Left inside a spaced stack it would pick up that spacing on both
    // sides as well as its own minimum, padding the column past the rail's
    // height and leaving dead space under the last step.
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        titleText
        if let whatHappened {
          TaskBoardStepStageBlock(
            label: "Just happened",
            systemImage: "clock.arrow.circlepath",
            text: whatHappened,
            tint: .secondary
          )
        }
        TaskBoardStepStageBlock(
          label: "Next",
          systemImage: "arrow.forward.circle",
          text: whatNext,
          tint: HarnessMonitorTheme.accent,
          emphasized: true
        )
      }
      // Drops the action slot to the bottom of the detail column so its
      // controls land on the panel's bottom edge rather than floating under the
      // copy. At its minimum it is exactly the stack's own gap, so a stage
      // whose copy already fills the column looks untouched.
      Spacer(minLength: HarnessMonitorTheme.spacingMD)
      actions
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier("harness.task-board.step.stage-card")
  }

  private var titleText: some View {
    Text(stageTitle)
      .font(titleFont)
      .accessibilityAddTraits(.isHeader)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// A labelled explanation block inside the stage card. The forward-looking
/// "Next" block is emphasized with a leading accent rule.
private struct TaskBoardStepStageBlock: View {
  let label: String
  let systemImage: String
  let text: String
  let tint: Color
  var emphasized = false

  @Environment(\.fontScale)
  private var fontScale

  private var labelFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }
  private var bodyFont: Font {
    HarnessMonitorTextSize.scaledFont(.callout, by: fontScale)
  }

  private static let ruleWidth: CGFloat = 3

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Label(label, systemImage: systemImage)
        .font(labelFont)
        .foregroundStyle(tint)
      Text(text)
        .font(bodyFont)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.leading, emphasized ? Self.ruleWidth + HarnessMonitorTheme.spacingSM : 0)
    // The rule rides in an overlay rather than beside the text in an HStack: a
    // Capsule is flexible in both axes, so as an HStack sibling it soaked up
    // whatever height the card was offered and left the block stretched far
    // below its own text. An overlay is proposed the content's size instead.
    .overlay(alignment: .leading) {
      if emphasized {
        Capsule().fill(tint.opacity(0.55)).frame(width: Self.ruleWidth)
      }
    }
    .accessibilityElement(children: .combine)
  }
}
