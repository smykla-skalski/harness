import SwiftUI

/// The focused stage card: what just happened, what Next will do, and a slot for
/// the stage's primary and secondary controls. Presentational only - the parent
/// supplies the action buttons so this view stores no action closures.
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
    HarnessMonitorTextSize.scaledFont(.headline.weight(.semibold), by: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      Text(stageTitle)
        .font(titleFont)
        .accessibilityAddTraits(.isHeader)
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
        tint: HarnessMonitorTheme.accent
      )
      actions
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(HarnessMonitorTheme.spacingMD)
    .background(HarnessMonitorTheme.ink.opacity(0.035), in: .rect(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(HarnessMonitorTheme.ink.opacity(0.12))
    }
    .accessibilityIdentifier("harness.task-board.step.stage-card")
  }
}

/// A labelled explanation block inside the stage card.
private struct TaskBoardStepStageBlock: View {
  let label: String
  let systemImage: String
  let text: String
  let tint: Color

  @Environment(\.fontScale)
  private var fontScale

  private var labelFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }
  private var bodyFont: Font {
    HarnessMonitorTextSize.scaledFont(.callout, by: fontScale)
  }

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
    .accessibilityElement(children: .combine)
  }
}
